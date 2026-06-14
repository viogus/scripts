# oci-helper Docker

[oci-helper](https://github.com/Yohann0617/oci-helper) — Oracle Cloud Infrastructure 可视化管理面板。

自建镜像：Maven 源码编译 → JRE Alpine 运行时。entrypoint 自动生成配置，**零宿主机操作**即可部署。

## 优化对比

| 维度 | 官方 | 本镜像 |
|------|------|--------|
| 容器数 | 3 (app + watcher + websockify) | 2 (app + websockify) |
| 基础镜像 | JDK | eclipse-temurin:21-jre-alpine |
| 预计大小 | ~400MB+ | ~250MB |
| 部署前操作 | 下载 4 个文件，创建目录，编辑配置 | **零操作**，仅设 env |
| 更新器 | 独立 watcher | 手动 `docker compose pull` |

## 快速部署

### Portainer Stack

直接粘贴，改 `OCI_PASSWORD`：

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

  websockify:
    image: ghcr.io/yohann0617/oci-helper-websockify:master
    restart: unless-stopped
    ports:
      - "6080:6080"

volumes:
  oci-helper-data:
```

Deploy 后访问 `http://<ip>:8818`，用上面的用户名密码登录。

### docker-compose

```bash
mkdir oci-helper && cd oci-helper
# 直接复制上面的 yaml 到 docker-compose.yml
docker compose up -d
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OCI_USERNAME` | `admin` | 网页登录账号 |
| `OCI_PASSWORD` | 随机 16 位 | 网页登录密码 |
| `JAVA_OPTS` | `-Xms256m -Xmx512m` | JVM 参数 |

> `OCI_PASSWORD` 留空则自动生成随机密码，查看日志获取：`docker logs oci-helper`

## 自定义 application.yml

如需更复杂的配置，挂载自定义 `application.yml`：

```yaml
volumes:
  - ./application.yml:/app/oci-helper/application.yml
  - oci-helper-data:/app/oci-helper
```

检测到已挂载配置文件时，跳过 env 自动生成。

## 持久化

数据全在 `/app/oci-helper/` 下：

| 文件 | 说明 |
|------|------|
| `oci-helper.db` | SQLite 数据库 |
| `keys/` | OCI API 密钥 (.pem) |
| `application.yml` | 应用配置 (自动生成) |

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
