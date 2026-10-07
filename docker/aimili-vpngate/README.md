# aimili-vpngate Docker

[AimiliVPN](https://github.com/OpenMili/aimili-vpngate) — 基于 VPNGate 公开节点的 SOCKS5/HTTP 代理网关。零 Python 依赖，纯标准库。

**镜像**：`ghcr.io/viogus/aimili-vpngate:latest`（~40MB，Alpine 多阶段构建）

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

首次启动时自动生成 `ui_auth.json` 并打印凭据。已持久化时跳过生成。

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

| 策略 | 节省 |
|------|------|
| Alpine 基础镜像（~7MB vs Debian ~74MB） | ~67MB |
| 多阶段构建（git 不入最终镜像） | ~15MB |
| 剥离 Python stdlib 无用模块（turtledemo/idlelib/test/lib2to3/ensurepip） | ~20MB |
| 清理 `__pycache__` / `.pyc` / `.pyo` | ~2MB |
| 单次 `apk add` + heredoc RUN（减少层） | — |

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
