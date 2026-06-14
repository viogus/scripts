# oci-helper Docker

[oci-helper](https://github.com/Yohann0617/oci-helper) — Oracle Cloud Infrastructure 可视化管理面板。自建镜像，精简部署。

## 优化对比

| 维度 | 官方 | 本镜像 |
|------|------|--------|
| 容器数 | 3 (app + watcher + websockify) | 2 (app + websockify) |
| 基础镜像 | 未知 (JDK) | eclipse-temurin:21-jre-alpine |
| 构建 | 未知 | Maven 多阶段 (源码编译) |
| 预计大小 | ~400MB+ | ~250MB |
| 更新器 | 独立 watcher 容器 | 无 (手动 `docker compose pull`) |

## 快速部署

```bash
mkdir oci-helper && cd oci-helper

# 1. 下载配置模板
curl -LO https://github.com/Yohann0617/oci-helper/releases/download/deploy/application.yml

# 2. 编辑账号密码
vim application.yml  # 搜索 security.user 修改 name/password

# 3. 下载 docker-compose.yml
curl -LO https://raw.githubusercontent.com/viogus/scripts/main/docker/oci-helper/docker-compose.yml

# 4. 创建 keys 目录并启动
mkdir -p keys
touch oci-helper.db
docker compose up -d
```

访问 `http://<ip>:8818`

## Portainer Stack

```yaml
version: "3.8"
services:
  oci-helper:
    image: ghcr.io/viogus/oci-helper:latest
    restart: unless-stopped
    ports:
      - "8818:8818"
    volumes:
      - /host/path/application.yml:/app/oci-helper/application.yml
      - /host/path/oci-helper.db:/app/oci-helper/oci-helper.db
      - /host/path/keys:/app/oci-helper/keys
    environment:
      - JAVA_OPTS=-Xms256m -Xmx512m

  websockify:
    image: ghcr.io/yohann0617/oci-helper-websockify:master
    restart: unless-stopped
    ports:
      - "6080:6080"
```

> 在 Portainer 中创建 stack 时，将 `/host/path/` 替换为实际宿主机路径。`application.yml` 和 `oci-helper.db` 需预先创建。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `JAVA_OPTS` | `-Xms256m -Xmx512m` | JVM 参数 |

## 持久化

| 路径 | 说明 |
|------|------|
| `./application.yml` | 应用配置 (账号密码等) |
| `./oci-helper.db` | SQLite 数据库 |
| `./keys/` | OCI API 密钥 (.pem) |

官方 install 脚本会拉取默认 `application.yml` 和 `oci-helper.db`。我们这里手动管理。

## Nginx 反代 (推荐)

```nginx
server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate     /path/to/cert.crt;
    ssl_certificate_key /path/to/private.key;

    location / {
        proxy_pass http://127.0.0.1:8818;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /myvnc/ {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 10800s;
    }
}
```

## 构建

```bash
docker build --build-arg OCI_HELPER_VERSION=v3.5.0 -t oci-helper .
```
