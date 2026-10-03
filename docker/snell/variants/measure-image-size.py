#!/usr/bin/env python3
"""量一个 `docker save` 出来的归档（OCI layout）里各层与整镜像的真实体积。

用法：
    docker save <image> -o /tmp/img.tar
    python3 measure-image-size.py /tmp/img.tar [<label>] [/tmp/img2.tar ...]

为什么不用 `docker images` 的 SIZE：containerd 镜像仓库下它会把多平台 manifest
一起算进去（例如 alpine:3.20 显示 25.8MB，而单平台实际只有 ~3.5MB 压缩）。

这里给的是**单平台**口径：
  * 压缩大小 = OCI blob 文件本身的字节数（registry 上真正传输的量）
  * 解压大小 = blob 的 gzip 尾部 ISIZE 字段（落盘后的量）
"""
import json
import os
import shutil
import struct
import sys
import tarfile


def gzip_isize(path):
    """原始（解压后）大小：gzip 尾部的 ISIZE 字段（小端 u32）。"""
    with open(path, "rb") as f:
        f.seek(-4, os.SEEK_END)
        return struct.unpack("<I", f.read(4))[0]


def measure(archive, label=None):
    label = label or os.path.basename(archive)
    d = archive + ".x"
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    try:
        with tarfile.open(archive) as tf:
            tf.extractall(d, filter="data")

        blobdir = os.path.join(d, "blobs", "sha256")
        if not os.path.isdir(blobdir):  # 老式 docker save 格式
            print(f"\n### {label}: classic docker format, tar={os.path.getsize(archive)/1048576:.3f} MB")
            return

        def blobs(manifests):
            for m in manifests:
                p = os.path.join(blobdir, m["digest"].split(":")[1])
                if os.path.exists(p):
                    yield m, json.load(open(p))

        def find_image(manifests, depth=0):
            """递归穿过嵌套 index / manifest list，找到真正的镜像 manifest。"""
            if depth > 3:
                return None
            for _, j in blobs(manifests):
                if "layers" in j:
                    return j
                if "manifests" in j:
                    found = find_image(j["manifests"], depth + 1)
                    if found:
                        return found
            return None

        idx = json.load(open(os.path.join(d, "index.json")))
        target = find_image(idx["manifests"])
        if target is None:
            print(f"\n### {label}: no image manifest found in index")
            return

        cfg = json.load(open(os.path.join(blobdir, target["config"]["digest"].split(":")[1])))
        rows = []
        for layer in target["layers"]:
            p = os.path.join(blobdir, layer["digest"].split(":")[1])
            comp = layer["size"]
            raw = gzip_isize(p) if layer["mediaType"].endswith("gzip") else comp
            rows.append((raw, comp, layer.get("annotations", {}).get("org.opencontainers.image.title", "")))

        raw_total = sum(r[0] for r in rows)
        comp_total = sum(r[1] for r in rows)
        print(f"\n### {label}  (linux/{cfg.get('architecture')})")
        print(f"  层数: {len(rows)}")
        for i, (raw, comp, title) in enumerate(rows):
            print(f"    layer {i}: {raw/1048576:8.3f} MB 解压 / {comp/1048576:7.3f} MB 压缩   {title}")
        print(f"  镜像(单平台) 解压合计: {raw_total/1048576:.3f} MB   (+config {target['config']['size']/1024:.1f} KB)")
        print(f"  镜像(单平台) 压缩合计: {comp_total/1048576:.3f} MB")
        print(f"  docker save 整包:      {os.path.getsize(archive)/1048576:.3f} MB")
    finally:
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)
    for arg in sys.argv[1:]:
        if arg.endswith(".tar"):
            measure(arg)
        else:
            print(f"skip (not a .tar): {arg}", file=sys.stderr)
