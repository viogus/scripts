# shadowsocks-rust Docker

上游 [`ghcr.io/shadowsocks/ssserver-rust`](https://github.com/shadowsocks/shadowsocks-rust/pkgs/container/ssserver-rust) 的翻版：同一套二进制，额外执行一次 `apk upgrade`，用来消掉 Alpine 基础镜像里**已经修好但上游没重建**的 CVE。

## 为什么自建

| 项 | 情况 |
|----|------|
| 上游最后构建 | `2026-08-26T22:41:11Z`（Alpine 3.24.1，shadowsocks-rust 1.25.0） |
| 上游 arm64 manifest | `sha256:22240c07d8ce3a36421ede770bd775dcc5fc56d5d829943196957b05452dc36f`（`docker pull` 拿到的就是这个，说明没重建过） |
| Trivy 扫描（Arcane 内置扫描器） | **21 条可修 CVE**：0 critical / 2 high / 7 medium / 12 low |
| 根因 | `libcrypto3`、`libssl3` 3.5.7-r0（→ 3.5.8-r0，含 high `CVE-2026-14456`）、`zlib` 1.3.2-r0（→ 1.3.2-r1） |
| 自建镜像 | openssl **3.5.9-r0** / zlib **1.3.2-r1** / Alpine **3.24.2**，ssserver 仍为 1.25.0 |
| 复扫结果 | **0 条**（同一套 Trivy + 同一个 trivy-db 镜像） |

结论：这种情况 `docker pull` 无效——上游不重建，本地只能自己重建。

## 镜像

| 镜像 | 平台 | 说明 |
|------|------|------|
| `ghcr.io/viogus/shadowsocks-server-rust:latest` `:1.25.0` `:upstream-<12hex>` | linux/amd64, arm64 | 生产使用（wrt 上的 `shadowsocks-server`） |
| `ghcr.io/viogus/ssserver-rust:latest` `:1.25.0` `:upstream-<12hex>` | linux/amd64, arm64 | 同一次构建的旧名字，保留兼容 |

`:upstream-<12hex>` 是构建时上游 `ssserver-rust:latest` 的 manifest digest 前 12 位（当前 `upstream-22240c07d8ce`），便于回溯当次构建的基础镜像。

* `shadowsocks-server-rust` manifest list：`sha256:21669e46a90bcb1c99bc0a9044716c8c97e94b755e0882e4b5666b5e6c686471`
* `ssserver-rust` manifest list：`sha256:1c18ccf47d2addda55afa429b84fbccf6e1930681b01fb1c2b09b497694ac35a`

> GHCR 新建的包默认是 **private**，首次推送后要到 package settings 里把可见性改成 Public，否则没有凭据的宿主机拉不到（报 `unauthorized`）。

## 构建

```bash
docker buildx build --platform linux/arm64,linux/amd64 \
  -t ghcr.io/viogus/shadowsocks-server-rust:latest \
  -t ghcr.io/viogus/shadowsocks-server-rust:1.25.0 \
  -t ghcr.io/viogus/ssserver-rust:latest \
  -t ghcr.io/viogus/ssserver-rust:1.25.0 --push .
```

## 验证

用 Arcane 内置扫描器**同一个** Trivy 镜像与数据库镜像，避免版本差异：

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/getarcaneapp/tools:latest trivy image \
  --db-repository ghcr.io/getarcaneapp/trivy-db:2 \
  --java-db-repository ghcr.io/getarcaneapp/trivy-java-db:1 \
  --checks-bundle-repository ghcr.io/getarcaneapp/trivy-checks:1 \
  --scanners vuln --no-progress \
  ghcr.io/viogus/shadowsocks-server-rust:latest
```

对比示例（2026-10-16）：上游镜像 21 条 → 本镜像 0 条。

## 部署

参数与原来的上游镜像完全一致，客户端无需改动：

```yaml
services:
  shadowsocks:
    image: ghcr.io/viogus/shadowsocks-server-rust:latest
    container_name: shadowsocks-server
    network_mode: host
    restart: always
    environment:
      - TZ=Asia/Shanghai
    command: ssserver -U -s 0.0.0.0:24000 -m chacha20-ietf-poly1305 -k <password>
```

等价的 `docker run`：

```bash
docker run -d --name shadowsocks-server --network host --restart always \
  -e TZ=Asia/Shanghai \
  ghcr.io/viogus/shadowsocks-server-rust:latest \
  ssserver -U -s 0.0.0.0:24000 -m chacha20-ietf-poly1305 -k <password>
```

## 更新

`.github/workflows/build-shadowsocks.yml` 负责自动重建：

* **触发**：`docker/shadowsocks/**` 或该 workflow 本身的 push、每周一 `03:37 UTC` 定时、`workflow_dispatch` 手动；
* **构建**：`docker buildx`（linux/amd64 + linux/arm64），`pull: true` + `no-cache: true`——保证每次都重新解析上游基础镜像、并且 `apk upgrade` 真的去 Alpine 仓库取当前安全包（不会被层缓存糊弄）；
* **标签**：两个包名各推 `latest` 和 `upstream-<上游 digest 前 12 位>`；
* **可见性**：两个 GHCR 包都已存在且为 public，CI 用 `GITHUB_TOKEN` 推送既不会新建包也不会改可见性。

手动重建（本地，含 `1.25.0` 版本标签）：见上面「构建」。上游是否重建过，用 `docker manifest inspect ghcr.io/shadowsocks/ssserver-rust:latest` 对比 digest 即可。
