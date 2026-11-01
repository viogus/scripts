#!/usr/bin/env python3
"""Keep only the integrations this box actually needs.

Home Assistant ships ~1500 integrations; one household needs a couple of dozen
plus their declared dependencies.  Three sources feed the keep set, so it
follows the HA version instead of a hard-coded list:

  1. the seeds we pass in (the platforms this box really uses);
  2. every `dependencies` entry in the kept integrations' manifest.json;
  3. every `homeassistant.components.<domain>` import found in core code
     (helpers/*, bootstrap.py, ...) and in the kept integrations — HA core
     imports a few integrations directly (`logger`, `config`, ...), which a
     manifest-only closure would miss.

Environment:
    HA_COMPONENTS  path to .../site-packages/homeassistant/components
    KEEP_SEEDS     space separated integration domains to keep
    DROP_PACKAGES  optional space separated pip packages to uninstall

Unknown seeds are reported and skipped, so a renamed integration does not fail
the whole build.
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

COMPONENTS = Path(os.environ["HA_COMPONENTS"])
HA_PKG = COMPONENTS.parent
SEEDS = [s for s in os.environ.get("KEEP_SEEDS", "").split() if s]
DROP = [s for s in os.environ.get("DROP_PACKAGES", "").split() if s]
# 明确不要的组件域：即使它是实体平台、或别的组件在 import 它，也照样删掉。
# 用于「这台机器不看摄像头」这类整条链路的下线，删的人自己保证依赖方也用不上。
SKIP = {s for s in os.environ.get("SKIP_DOMAINS", "").split() if s}

DOMAIN_RE = re.compile(r"^[a-z0-9_]+$")


def existing(domain: str) -> bool:
    return (COMPONENTS / domain / "__init__.py").is_file()


def package_parts(path: Path) -> list[str]:
    """Dotted package of a file inside the homeassistant package, e.g. ['homeassistant', 'helpers']."""
    rel = path.relative_to(HA_PKG.parent).with_suffix("")
    return list(rel.parts)[:-1]  # drop the module / __init__ file name


def imports_in(path: Path) -> set[str]:
    """Integrations imported by one module (absolute or relative imports)."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="ignore"))
    except (OSError, SyntaxError):  # pragma: no cover - defensive
        return set()

    pkg = package_parts(path)
    found: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.ImportFrom):
            continue
        if node.level:
            base = pkg[: len(pkg) - node.level + 1]
            module = (node.module or "").split(".") if node.module else []
            base = base + module
            names = [alias.name for alias in node.names]
        else:
            module = (node.module or "").split(".")
            base = ["homeassistant"] + module if module[:1] != ["homeassistant"] else module
            names = [alias.name for alias in node.names]

        if base[:2] != ["homeassistant", "components"]:
            continue
        if len(base) >= 3:
            found.add(base[2])
        else:
            found.update(name for name in names if DOMAIN_RE.match(name))

    return {d for d in found if existing(d) and d not in SKIP}


def scan_core() -> set[str]:
    found: set[str] = set()
    for path in HA_PKG.rglob("*.py"):
        if COMPONENTS in path.parents:
            continue
        found |= imports_in(path)
    return found


def platform_domains() -> set[str]:
    """Every entity platform domain (date, time, weather, ...).

    The frontend asks for their translations unconditionally, and integrations
    create these platforms, so they are cheap and always kept.
    """
    src = (HA_PKG / "generated" / "entity_platforms.py").read_text(encoding="utf-8")
    return {
        value
        for value in re.findall(r'^\s+[A-Z_0-9]+\s*=\s*"([a-z_0-9]+)"', src, re.M)
        if existing(value)
    }


def manifest_closure(seeds: set[str]) -> set[str]:
    """Seeds plus everything their manifests declare as a dependency.

    `after_dependencies` counts too: the requirements loader resolves them
    when the integration is set up, and raises IntegrationNotFound if the
    directory is gone (e.g. `switch` -> `switch_as_x`).
    """
    keep: set[str] = set()
    queue = list(seeds)
    missing: list[str] = []
    while queue:
        domain = queue.pop()
        if domain in keep:
            continue
        manifest = COMPONENTS / domain / "manifest.json"
        if not manifest.is_file():
            missing.append(domain)
            continue
        keep.add(domain)
        try:
            data = json.loads(manifest.read_text())
        except json.JSONDecodeError:  # pragma: no cover - defensive
            continue
        queue.extend(
            d
            for d in (data.get("dependencies") or []) + (data.get("after_dependencies") or [])
            if d not in keep
        )
    if missing:
        print(
            f"    seeds without a component dir (ignored): {' '.join(sorted(set(missing)))}",
            file=sys.stderr,
        )
    return keep


def main() -> int:
    keep = manifest_closure((set(SEEDS) | platform_domains()) - SKIP)

    # Import-driven fixpoint.  Modules that core code imports directly (bootstrap
    # pulls in `default_config`, `group`, ...) are kept as code only: their
    # manifests are not expanded, otherwise `default_config` would drag its
    # whole dependency tree (bluetooth, cloud, ...) back in.
    while True:
        extra: set[str] = scan_core()
        for domain in keep:
            for path in (COMPONENTS / domain).rglob("*.py"):
                extra |= imports_in(path)
        extra -= keep
        extra -= SKIP
        if not extra:
            break
        keep |= extra

    keep -= SKIP
    if SKIP:
        print(f"    skipped on request: {' '.join(sorted(SKIP))}", file=sys.stderr)
    victims = sorted(
        p.name
        for p in COMPONENTS.iterdir()
        if p.is_dir() and not p.name.startswith("__") and p.name not in keep
    )
    freed = 0
    for name in victims:
        path = COMPONENTS / name
        freed += sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        shutil.rmtree(path)

    print(
        f"    kept {len(keep)} integrations, removed {len(victims)}, "
        f"freed {freed / 1048576:.1f} MB",
        file=sys.stderr,
    )

    if DROP:
        subprocess.run(
            [sys.executable, "-m", "pip", "uninstall", "-y", *DROP],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        print(f"    uninstalled: {' '.join(DROP)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
