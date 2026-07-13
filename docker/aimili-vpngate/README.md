# aimili-vpngate Docker

[AimiliVPN](https://github.com/baoweise-bot/aimili-vpngate) — 基于 VPNGate 公开节点的 SOCKS5/HTTP 代理网关。零 Python 依赖，纯标准库。

**镜像**：`ghcr.io/viogus/aimili-vpngate:latest`（~40MB，Alpine 多阶段构建）

## 用法

### docker-compose（推荐）

```yaml
services:
  aimili-vpngate:
    image: ghcr.io/viogus/aimili-vpngate:latest
    restart: unless-stopped
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

首次启动时自动生成 `ui_auth.json` 并打印凭据。已持久化时跳过生成。

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

## CI

GitHub Actions 在以下情况自动构建并推送到 ghcr.io：

- **push** main 分支且 `docker/aimili-vpngate/**` 或 workflow 文件变更
- **schedule** 每周日 04:23 UTC（自动获取上游代码更新）
- **workflow_dispatch** 手动触发

支持 `linux/amd64` 和 `linux/arm64`。
