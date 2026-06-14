# oci-helper Docker

[oci-helper](https://github.com/Yohann0617/oci-helper) — Oracle Cloud Infrastructure 可视化管理面板。

自建镜像，精简部署。Maven 多阶段构建，JRE Alpine 运行时，非 root 用户运行。

## 优化对比

| 维度 | 官方 | 本镜像 |
|------|------|--------|
| 容器数 | 3 (app + watcher + websockify) | 2 |
| 基础镜像 | eclipse-temurin:21-jre-jammy (~200MB) | eclipse-temurin:21-jre-alpine (~80MB) |
| websockify | 外部镜像 | 自建 (python:3-alpine + pip) |
| 运行用户 | root | nobody (65534) |
| JVM GC | 默认 | G1GC + MaxGCPauseMillis=200 |
| 部署前操作 | 下载 4 个文件 | **零操作**，仅设 env |

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
      - oci-helper-data:/app/oci-helper
    environment:
      - OCI_USERNAME=admin
      - OCI_PASSWORD=your-secret-password
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8818"]
      interval: 30s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 512M

  websockify:
    image: ghcr.io/viogus/oci-helper-ws:latest
    restart: unless-stopped
    ports:
      - "6080:6080"

volumes:
  oci-helper-data:
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OCI_USERNAME` | `admin` | 网页登录账号 |
| `OCI_PASSWORD` | 随机 16 位 | 网页登录密码 |
| `JAVA_OPTS` | 见下 | JVM 参数 |

默认 JVM：`-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200`

## 自定义 application.yml

挂载自定义配置即跳过 env 自动生成：

```yaml
volumes:
  - ./application.yml:/app/oci-helper/application.yml
  - oci-helper-data:/app/oci-helper
```

## Nginx 反代

```nginx
server {
    listen 443 ssl http2;
    server_name your.domain;

    location / {
        proxy_pass http://127.0.0.1:8818;
        proxy_set_header Host $host;
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

## 镜像

| 镜像 | 说明 |
|------|------|
| `ghcr.io/viogus/oci-helper:latest` | 主应用 (amd64/arm64) |
| `ghcr.io/viogus/oci-helper-ws:latest` | websockify sidecar (amd64/arm64) |
