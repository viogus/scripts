# nodeget.sh Improvements Design

**Date:** 2026-05-26
**Status:** approved

## Summary

Four targeted fixes to the NodeGet management script (`nodeget.sh`):

## 1. grep -oP → sed (Alpine compat)

**Problem:** `grep -oP` uses Perl regex, unavailable in BusyBox grep (Alpine, OpenWrt). Token and password extraction silently returns "??".

**Fix:** Replace with POSIX `sed -nE`:

```bash
# Before
token=$(echo "$init_out" | grep -oP 'Super Token:\s*\K.*' || echo "??")

# After  
token=$(echo "$init_out" | sed -nE 's/.*Super Token:\s*//p' | head -1)
token="${token:-??}"
```

Same pattern for `account_password` (Root Password).

## 2. Add upgrade feature

**Problem:** No way to update binary without full reinstall and re-entering all config.

**Fix:** Add `upgrade_nodeget()` function and menu options 14 (update Server), 15 (update Agent). Flow: check installed → download latest binary → restart service. Config untouched, no `init` re-run.

## 3. Expand arch support + asset validation

**Problem:** Missing riscv64, powerpc64, powerpc64le, s390x, sparc64, thumbv7neon. No pre-flight check for arm/i686 server (which don't exist in releases).

**Fix:**
- Add 6 arch cases to `get_arch()`
- Add `check_asset()` — validates binary exists in release before attempting download
- Server on arm/i686: clear error message instead of generic "download failed"

## 4. Robust JSON parsing

**Problem:** `grep '"tag_name":'` fragile against whitespace/formatting changes in GitHub API response.

**Fix:** Use `sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([0-9.]+)".*/\1/p'` — handles spacing variation, picks first match to avoid nested key confusion.

---

## Scope

Single file: `nodeget.sh`. No changes to `menu.sh` or other scripts.
