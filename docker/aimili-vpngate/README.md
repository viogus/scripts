# aimili-vpngate Docker

[AimiliVPN](https://github.com/OpenMili/aimili-vpngate) — 基于 VPNGate 公开节点的 SOCKS5/HTTP 代理网关。零 Python 依赖，纯标准库。

**镜像**：`ghcr.io/viogus/aimili-vpngate:latest`（~36MB，Alpine 3.24 多阶段构建）

## 用法

### docker-compose（推荐）

```yaml
services:
  aimili-vpngate:
    image: ghcr.io/viogus/aimili-vpngate:latest
    restart: unless-stopped
    logging:                      # 容器 stdout 是 vpngate.log 的第二份拷贝，一并限制
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    ports:
      - "8787:8787"   # web 管理面板
      - "7928:7928"   # SOCKS5/HTTP 代理
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.rp_filter=2
      - net.ipv4.conf.default.rp_filter=2
    volumes:
      - ./aimili-data:/opt/aimilivpn/vpngate_data
    environment:
      - WEB_PORT=8787
      # - WEB_USERNAME=admin        # 可选，默认随机生成
      # - WEB_PASSWORD=your_pass    # 可选，默认随机生成
      # - SECRET_PATH=mysecret      # 可选，默认随机生成
      # - LOCAL_PROXY_USER=proxy    # 可选，SOCKS5/HTTP 代理认证用户名
      # - LOCAL_PROXY_PASS=pwd      # 可选，SOCKS5/HTTP 代理认证密码
      # - VPNGATE_COUNTRY=KR        # 可选，只在该国家内选最优连接（韩国/Korea 亦可）
      # - VPNGATE_COUNTRY_LOCK=0    # 可选，只收窄候选池，失效可回退到其他国家
      # - VPNGATE_LOG_MAX_BYTES=16777216   # 可选，vpngate.log 单文件上限（字节），0 = 不轮转
      # - VPNGATE_LOG_BACKUP_COUNT=3       # 可选，保留的 vpngate.log.N 历史份数
```

### docker run

```bash
docker run -d \
  --name aimili-vpngate \
  --restart unless-stopped \
  -p 8787:8787 \
  -p 7928:7928 \
  --device /dev/net/tun:/dev/net/tun \
  --cap-add NET_ADMIN \
  --sysctl net.ipv4.conf.all.rp_filter=2 \
  --sysctl net.ipv4.conf.default.rp_filter=2 \
  -v ./aimili-data:/opt/aimilivpn/vpngate_data \
  ghcr.io/viogus/aimili-vpngate:latest
```

启动后查看日志获取 Web 管理面板地址和登录凭据：

```bash
docker logs aimili-vpngate
```

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `WEB_PORT` | `8787` | Web 管理面板端口 |
| `WEB_USERNAME` | 随机 12 位 | 登录用户名 |
| `WEB_PASSWORD` | 随机 12 位 | 登录密码 |
| `SECRET_PATH` | 随机 12 位 | URL 路径后缀 |
| `LOCAL_PROXY_USER` | (空) | SOCKS5/HTTP 代理认证用户名。设置后代理必须认证。 |
| `LOCAL_PROXY_PASS` | (空) | SOCKS5/HTTP 代理认证密码。设置后代理必须认证。 |
| `VPNGATE_LOG_MAX_BYTES` | `16777216`（16 MiB） | `vpngate.log` 单文件上限（字节）。`0` = 关闭轮转（旧行为，会无限增长）。 |
| `VPNGATE_LOG_BACKUP_COUNT` | `3` | 保留 `vpngate.log.1 .. .N` 的历史份数；`0` = 只截断不留档。 |
| `VPNGATE_COUNTRY` | (空) | 只在该国家/地区内选节点。ISO 两字母代码（`KR`）或面板里的国家名（`韩国`/`Korea`），多个用逗号分隔（`KR,JP`）。单国时同时把路由模式锁定为「固定地区」。 |
| `VPNGATE_COUNTRY_LOCK` | `1` | `0` = 只收窄候选池、不锁定路由；该国节点全部失效时仍可回退到其他国家。 |

首次启动时自动生成 `ui_auth.json` 并打印凭据。已持久化时跳过生成。

## 指定国家/地区

想让容器只在某个国家内挑最优连接，compose 里加一行即可，不必登录面板改设置：

```yaml
    environment:
      - VPNGATE_COUNTRY=KR        # 或 韩国 / Korea；多个用逗号分隔，如 KR,JP
```

- **单国**（`KR`）：候选池只保留该国节点（后台并发测速也只测这些），并把路由模式
  锁定为「固定地区」，只连该国延迟/评分最优的节点。该国节点全部失效时**不会**自动
  切到其他国家——这是上游 `fixed_region` 的既定行为。候选数因国而异：内置快照里
  韩国 24 个、日本 58 个（全部约 100 个候选、10 个国家），实测韩国在线 22 个左右，
  通常够用；国家越小越建议配合 `VPNGATE_COUNTRY_LOCK=0`。
- **多国**（`KR,JP`）：只收窄候选池，路由模式保持 `auto`，在这几国范围内挑最优，
  并允许自动切换。
- `VPNGATE_COUNTRY_LOCK=0`：只收窄候选池、不锁定路由——「优先在该国选，全军覆没
  时回退到其他国家」。
- 环境变量**每轮读取都优先于** `ui_auth.json`：面板里手动改「路由模式/国家」会被
  下一轮覆盖，面板上也会直接显示被强制生效的值。删掉这行重启容器后环境变量不再
  参与，但 `ui_auth.json` 里仍是上一次被环境变量写入的 `fixed_region` +
  `force_country`——要到面板里改回 `auto`（或删除 `vpngate_data/ui_auth.json`
  让它按默认值重建）才会真正解除锁定。
- 用国家名（`韩国`/`Korea`）时依赖 `vpngate_data/nodes.json` 里的国家字段做名称→
  代码映射：全新容器在第一轮抓取前可能还解析不出来（此时打印一条
  `[配置] VPNGATE_COUNTRY=... 无法解析为国家代码` 提示），抓取一轮后自动生效；
  直接写 ISO 代码（`KR`）没有这个延迟。

该能力来自 `patches/0002-country-selection.patch`（上游没有这个环境变量），挂在
`load_ui_config()` 上，与 `patches/0001` 一样在构建期应用。

## 日志与磁盘占用

进程的 stdout/stderr 会同时写入 `vpngate_data/vpngate.log`。上游代码不做轮转，
长期运行会一直增长（实测约 150 MB/天，曾有容器涨到 768 MB），因此镜像内置了
一个构建期补丁 `patches/0001-bounded-log-rotation.patch`：写满
`VPNGATE_LOG_MAX_BYTES` 就轮转，最多保留 `VPNGATE_LOG_BACKUP_COUNT` 份历史，
默认最坏占用约 64 MiB。面板的「运行日志」读的是 `vpngate_data/logs/<日期>.json`
（程序自己保留 3 天），与 `vpngate.log` 无关，轮转不影响面板。

容器 stdout 由 Docker 的 `json-file` 驱动另行落盘，同样会无限增长——compose 里
建议保留上面示例中的 `logging` 限制；已存在的容器需要重建才能生效：

```bash
: > ./aimili-data/vpngate.log    # 可选：升级前先清掉旧的超大日志，立即回收空间
docker compose up -d             # 重建容器，应用 logging 限制与新版镜像
```

## 使用代理

容器启动后，代理监听 `7928` 端口（SOCKS5 + HTTP）：

```bash
# Shell
export http_proxy="http://127.0.0.1:7928"
export https_proxy="http://127.0.0.1:7928"
curl https://ipinfo.io

# 或 SOCKS5
export ALL_PROXY="socks5://127.0.0.1:7928"

# 有认证时
export ALL_PROXY="socks5://user:pass@127.0.0.1:7928"
export http_proxy="http://user:pass@127.0.0.1:7928"
```

```python
# Python
import requests
proxies = {"http": "http://127.0.0.1:7928", "https": "http://127.0.0.1:7928"}
requests.get("https://www.google.com", proxies=proxies)
```

## 管理

打开 Web 面板 → 点击「更新节点」→ 选择路由模式 → 代理就绪。

## 要求

- 宿主机需加载 `tun` 内核模块：`lsmod | grep tun`
- Docker 需 `--device /dev/net/tun --cap-add NET_ADMIN`
- LXC/OpenVZ 需在面板启用 TUN/TAP

## 镜像优化

实测（arm64，单平台）：

| 口径 | 优化前 | 第一轮 | 第二轮 | 第三轮（当前） |
|------|--------|--------|--------|----------------|
| arm 主机 overlay2 未压缩 | 65.5MB | 43.5MB | 36.2MB | 31.4MB |
| OCI 压缩层合计（registry 真正传输量） | — | 14.63MB | 12.62MB | **10.61MB（-15.9%）** |
| 本地 colima `docker images` | 91.2MB | 61.3MB | 51.7MB | 44.7MB |

| 策略 | 说明 | 节省 |
|------|------|------|
| Alpine 基础镜像 + 多阶段构建 | `alpine:3.24`；`git`/`patch`/构建依赖只留在 builder 阶段 | 相对 Debian 单阶段 ~70MB |
| 去掉 `iptables`（含 `/usr/lib/xtables` 121 个文件） | 上游只在 VPS 环境自检里跑 `iptables -S`，try/except 包裹，缺二进制即跳过 | ~7.8MB |
| 去掉 `procps-ng` 与完整 `iproute2`/`iproute2-tc` | `openvpn` 自己依赖 `iproute2-minimal`（提供 `/sbin/ip`）；`sysctl/ps/pgrep/pkill/free/nproc/route/ping` 都用 busybox 内建 | ~3.3MB |
| `ca-certificates` → `ca-certificates-bundle` | 只保留 CA 证书包，不装完整 ca-certificates | ~0.5MB |
| 剥离未被导入的 stdlib 模块 | `ensurepip/pydoc_data/unittest/asyncio/multiprocessing/xml/dbm/curses/sqlite3/turtle/test*` 等；`email` 必须保留（`http.server` 依赖） | ~7.0MB |
| 删除只被上述模块链接的共享库 | `libsqlite3/libreadline/libncursesw/libpanelw` | ~2.4MB |
| 清 `__pycache__`/`.pyc`，语法校验加 `-B` | 否则校验本身会重新生成缓存（该层 581kB → 4kB） | ~0.6MB |
| 删除运行期用不到的仓库文件 | `.github`/`docs`/`tests`/`scripts`/`install.sh`/`*.md`/`compose.yaml`；`mirror/` 必须保留（离线节点快照回退） | ~0.2MB |
| 剥离未被引用的 stdlib C 扩展 | `_decimal/_bz2/_lzma/_elementtree/_zoneinfo/_asyncio/_multiprocessing/_lsprof/_statistics/xxlimited*` 等；应用只 import 22 个模块，`_codecs_*` 一并去掉 | ~2.4MB |
| 去掉只用于非 UTF-8 的编解码器 | 源码里 22 处 `encoding="utf-8"`，无第二种编码，故删 `encodings/{big5,cp*,euc*,gb*,iso2022*,shift_jis*,koi8*,...}` | ~1.1MB |
| 删除只被这些模块链接的共享库 | `libbz2/liblzma/libffi/libexpat/libgdbm*/libmpdec*/libstdc++`（用 `scanelf -R -F "%F: %n"` 逐个核对引用方）。**`libelf` 必须保留**：`/sbin/ip` 依赖它 | ~3.7MB |
| 去掉 `curl` 及其整条 https 依赖链 | 补丁 `0003-drop-curl-exit-ip-probe.patch` 把唯一的 curl 调用点（`check_proxy_health` 里的出口 IP 探测）换成标准库 SOCKS5 客户端，于是 `curl`+`libcurl/libbrotli*/libc-ares/libidn2/libpsl/libunistring/libnghttp2` 全删。`apk` 自带 HTTP 客户端、不依赖 libcurl；`libzstd` 保留（`/sbin/ip` → `libelf` → `libzstd`） | ~4.6MB |

三个坑，已在 Dockerfile 内注释：

- `/bin/sh` 是 busybox ash，**不展开 `{a,b}` 花括号**。旧版写的
  `rm -rf /usr/lib/python3.*/{turtledemo,idlelib,...}` 一直静默无效（`ensurepip`、
  `turtledemo` 始终留在镜像里），现改为显式循环 + `find`。
- 语法校验要用 `python3 -B`，否则它按需生成 `.pyc`，把刚删掉的缓存又长回来。
- **删除必须和 `apk add` 在同一个 RUN 层**。镜像体积是各层之和，在后续层
  `rm` 只是加一层 whiteout，前面的字节照样存在（实测：同一套剪裁放到后一层，
  镜像 42.30MB → 42.30MB，一点没变）。

容器内已无 `iptables`、`sqlite3`、`curses`、`curl`：上游仅在 VPS 自检里可选调用
`iptables`，其余模块从不导入；出口 IP 探测改由补丁 0003 用标准库完成，不影响节点
选择与代理功能。

底座选型也验证过：换 `scratch` 只省 0.3MB（-2%），还丢掉 `apk`；换 Tiny Core
（piCore rootfs，底座 2.41MiB vs alpine 3.99MiB 压缩）理论上限约 -11%，但
Python/OpenVPN 没有 aarch64 包，得为 glibc 从源码重编，收益还不如上面这几轮
载荷剪裁。结论：**保留 Alpine，体积从载荷里省**。

## 构建

```bash
docker build -t aimili-vpngate docker/aimili-vpngate
```

构建时 clone 上游 `OpenMili/aimili-vpngate`（默认 `main`，可用
`--build-arg UPSTREAM_REF=v2.1.5` 固定到某个 tag/分支）并依次应用
`patches/*.patch`。补丁打不上会直接让构建失败并用 `!!!` 打印文件名——说明上游
改了对应代码，需要先 rebase 补丁再发布。

## CI

GitHub Actions 在以下情况自动构建并推送到 ghcr.io：

- **push** main 分支且 `docker/aimili-vpngate/**` 或 workflow 文件变更
- **schedule** 每周日 04:23 UTC（自动获取上游代码更新）
- **workflow_dispatch** 手动触发

支持 `linux/amd64` 和 `linux/arm64`。
