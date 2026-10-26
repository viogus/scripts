#!/bin/sh
# Home Assistant 容器入口：先把镜像里预装的 custom_components 播种到配置目录，
# 再把控制权交给 hass。
#
# 为什么需要这一步：HA 只从 <config>/custom_components 加载自定义集成，而 /data
# 通常是宿主机 bind mount —— 镜像里写进 /data 的文件会被挂载点整个盖住（named
# volume 首次创建会拷一份，bind mount 不会）。所以预装的集成放在
# /usr/local/share/homeassistant/custom_components，启动时按需补进配置目录。
#
# 已存在的同名集成一律不动：用户可能用 HACS 装过、或手动升级到了更新的版本，
# 覆盖它属于越权。
set -eu

CONFIG_DIR="${CONFIG_DIR:-/data}"
SEED_DIR="/usr/local/share/homeassistant/custom_components"

seed_custom_components() {
    [ -d "$SEED_DIR" ] || return 0

    if ! mkdir -p "$CONFIG_DIR/custom_components" 2>/dev/null; then
        echo "[entrypoint] WARN: cannot create $CONFIG_DIR/custom_components;" \
             "skip seeding (read-only mount, or running as a user without write access)" >&2
        return 0
    fi

    for src in "$SEED_DIR"/*/; do
        [ -d "$src" ] || continue
        name=$(basename "$src")
        dst="$CONFIG_DIR/custom_components/$name"
        if [ -e "$dst" ]; then
            echo "[entrypoint] custom_components/$name already exists, left untouched"
        elif cp -a "$src" "$dst" 2>/dev/null; then
            echo "[entrypoint] seeded custom_components/$name"
        else
            echo "[entrypoint] WARN: failed to seed custom_components/$name (permissions?)" >&2
        fi
    done
}

seed_custom_components

# 保持原来的用法：`docker run <img>` 和 `docker run <img> --debug` 都走 hass；
# 传别的命令（`bash`、`python3 ...`）就直接执行，方便排查问题。
case "${1:-}" in
    "")  exec hass --config="$CONFIG_DIR" ;;
    -*)  exec hass --config="$CONFIG_DIR" "$@" ;;
    *)   exec "$@" ;;
esac
