#!/bin/sh
# Home Assistant 容器入口。
#
# 两件事：
#   1. 选配置目录，并让 /config 和 /data 两个路径指向同一份数据（HA 生态默认
#      /config：官方镜像、文档、Samba/FTPS add-on 都是它；上游 kurapov 镜像用
#      /data）；
#   2. 把镜像里预装的 custom_components 播种进配置目录。
#
# 为什么需要 1：容器里两个路径统一，才不会出现“换镜像后配置突然变空、427 个实体
# 全没了”——官方镜像挂 /config，这个镜像原来只认 /data，切过来就踩这个坑。
#
# 为什么需要 2：/config 通常是 bind mount，镜像里写进去的内容会被挂载点整个盖住
# （named volume 只会在首次创建时拷一份）。所以预装集成放在
# /usr/local/share/homeassistant/custom_components，启动时按需补进配置目录。
# 已存在的同名集成一律不动：用户可能用 HACS 装过、或手动升级到了更新的版本。
set -eu

SEED_DIR="/usr/local/share/homeassistant/custom_components"

is_mountpoint() {
    # musl/busybox 里没有 findmnt，直接看 mountinfo
    [ -r /proc/self/mountinfo ] || return 1
    grep -qs " $1 " /proc/self/mountinfo
}

has_config() {
    [ -f "$1/configuration.yaml" ] || [ -d "$1/.storage" ]
}

pick_config_dir() {
    # 显式指定优先
    if [ -n "${CONFIG_DIR:-}" ]; then
        echo "$CONFIG_DIR"
        return 0
    fi
    # 已经有配置的目录优先；两个都有就按 HA 惯例选 /config
    if [ -d /config ] && has_config /config; then
        echo /config
        return 0
    fi
    if [ -d /data ] && has_config /data; then
        echo /data
        return 0
    fi
    # 全新安装：哪个挂着就用哪个，都没挂就按 HA 惯例 /config
    if is_mountpoint /data && ! is_mountpoint /config; then
        echo /data
        return 0
    fi
    echo /config
}

link_other_path() {
    config_dir="$1"
    for other in /config /data; do
        [ "$other" = "$config_dir" ] && continue
        # 挂载点不能盖成软链
        if is_mountpoint "$other"; then
            echo "[entrypoint] $other is a mountpoint, leaving it alone" >&2
            continue
        fi
        # 真实目录：空的（基础镜像里 /data 就是空的）可以换成软链，有内容的不动
        if [ -d "$other" ] && [ ! -L "$other" ]; then
            if [ -n "$(ls -A "$other" 2>/dev/null)" ]; then
                echo "[entrypoint] $other already has content, leaving it alone" >&2
                continue
            fi
            rm -rf "$other" 2>/dev/null || true
        fi
        rm -f "$other" 2>/dev/null || true
        if ln -sn "$config_dir" "$other" 2>/dev/null; then
            echo "[entrypoint] $other -> $config_dir"
        else
            echo "[entrypoint] WARN: cannot link $other -> $config_dir" >&2
        fi
    done
}

seed_custom_components() {
    config_dir="$1"
    [ -d "$SEED_DIR" ] || return 0

    if ! mkdir -p "$config_dir/custom_components" 2>/dev/null; then
        echo "[entrypoint] WARN: cannot create $config_dir/custom_components;" \
             "skip seeding (read-only mount, or running as a user without write access)" >&2
        return 0
    fi

    for src in "$SEED_DIR"/*/; do
        [ -d "$src" ] || continue
        name=$(basename "$src")
        dst="$config_dir/custom_components/$name"
        if [ -e "$dst" ]; then
            echo "[entrypoint] custom_components/$name already exists, left untouched"
        elif cp -a "$src" "$dst" 2>/dev/null; then
            echo "[entrypoint] seeded custom_components/$name"
        else
            echo "[entrypoint] WARN: failed to seed custom_components/$name (permissions?)" >&2
        fi
    done
}

seed_slim_config() {
    config_dir="$1"
    case "${HA_VARIANT:-full}" in slim|micro) ;; *) return 0 ;; esac
    # 只给全新安装种；已有 configuration.yaml 或 .storage 的一律不碰
    [ -f "$config_dir/configuration.yaml" ] && return 0
    [ -d "$config_dir/.storage" ] && return 0
    template=/usr/local/share/homeassistant/configuration.yaml.slim
    [ -f "$template" ] || return 0
    mkdir -p "$config_dir" 2>/dev/null || true
    if ! cp "$template" "$config_dir/configuration.yaml" 2>/dev/null; then
        echo "[entrypoint] WARN: cannot seed slim configuration.yaml" >&2
        return 0
    fi
    # 这些伴生文件平时由 HA 自己写（homeassistant/config.py 的
    # _write_default_config），但它只在 configuration.yaml 不存在时才动手 ——
    # 我们已经写了一份，所以得自己补齐，否则配置解析直接失败并进 recovery mode。
    [ -f "$config_dir/secrets.yaml" ] || : >"$config_dir/secrets.yaml"
    [ -f "$config_dir/automations.yaml" ] || printf '[]' >"$config_dir/automations.yaml"
    [ -f "$config_dir/scripts.yaml" ] || : >"$config_dir/scripts.yaml"
    [ -f "$config_dir/scenes.yaml" ] || : >"$config_dir/scenes.yaml"
    [ -d "$config_dir/themes" ] || mkdir -p "$config_dir/themes" 2>/dev/null || true
    echo "[entrypoint] seeded slim configuration.yaml (no default_config)"
}

CONFIG_DIR_PATH="$(pick_config_dir)"
echo "[entrypoint] config dir: $CONFIG_DIR_PATH"
link_other_path "$CONFIG_DIR_PATH"
warn_if_default_config() {
    config_dir="$1"
    case "${HA_VARIANT:-full}" in slim|micro) ;; *) return 0 ;; esac
    conf="$config_dir/configuration.yaml"
    [ -f "$conf" ] || return 0
    # 旧配置大多来自官方镜像，第一行就是 default_config:；slim/micro 没有它那批
    # 依赖（usb/ssdp/bluetooth…），实测会卡在 bootstrap，config entry 根本不 setup。
    if grep -qE '^[[:space:]]*default_config:' "$conf"; then
        echo "[entrypoint] WARN: $conf still loads default_config:, but this is the" \
             "${HA_VARIANT} variant which does not ship its dependencies." >&2
        echo "[entrypoint] WARN: expect setup failures (usb/ssdp/bluetooth) and a stalled" \
             "bootstrap; comment it out or switch to the full variant." >&2
        echo "[entrypoint] WARN: reference config: /usr/local/share/homeassistant/configuration.yaml.slim" >&2
    fi
}

seed_slim_config "$CONFIG_DIR_PATH"
warn_if_default_config "$CONFIG_DIR_PATH"
seed_custom_components "$CONFIG_DIR_PATH"

# 保持原来的用法：`docker run <img>` 和 `docker run <img> --debug` 都走 hass；
# 传别的命令（`bash`、`python3 ...`）就直接执行，方便排查问题。
case "${1:-}" in
    "")  exec hass --config="$CONFIG_DIR_PATH" ;;
    -*)  exec hass --config="$CONFIG_DIR_PATH" "$@" ;;
    *)   exec "$@" ;;
esac
