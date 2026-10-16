# shadowsocks-rust Docker

从上游 [`ghcr.io/shadowsocks/ssserver-rust`](https://github.com/shadowsocks/shadowsocks-rust/pkgs/container/ssserver-rust) 里取出那个**静态链接的 `ssserver` 二进制**，放到 `scratch` 空镜像上——体积只有上游的一半，而且一个 OS 包都没有。

## 为什么自建

| 项 | 情况 |
|----|------|
| 上游最后构建 | `2026-08-26T22:41:11Z`（Alpine 3.24.1，shadowsocks-rust 1.25.0） |
| 上游 arm64 manifest | `sha256:22240c07d8ce3a36421ede770bd775dcc5fc56d5d829943196957b05452dc36f`，`docker pull` 拿到的就是这个——说明没重建过 |
| Trivy 扫描（Arcane 内置扫描器） | **21 条可修 CVE**：0 critical / 2 high / 7 medium / 12 low，全部来自 Alpine 包（`libcrypto3`/`libssl3` 3.5.7-r0 → 3.5.8-r0，含 high `CVE-2026-14456`；`zlib` 1.3.2-r0 → 1.3.2-r1） |
| 上游镜像构成 | 真正干活的只有一个 8.3 MB 的静态 `ssserver`（`ELF, statically linked, stripped`），其余是一整套 Alpine userland |
| 本镜像做法 | 把那个二进制拷到 `scratch`，不再带任何 Alpine 包 |
| 结果 | **0 条**（Trivy 在这个镜像里没有任何可扫目标），压缩体积 8.08 MB → **4.09 MB** |

结论：上游不重建、OS 层却是 CVE 的来源；与其重打一遍 Alpine 补丁，不如干脆不要 OS 层。

## 镜像

| 镜像 | 平台 | 压缩体积 | 说明 |
|------|------|----------|------|
| `ghcr.io/viogus/shadowsocks-server-rust:latest` `:1.25.0` `:upstream-<12hex>` | linux/amd64, arm64 | 4.09 MB | 生产使用（wrt 上的 `shadowsocks-server`） |
| `ghcr.io/viogus/ssserver-rust:latest` `:1.25.0` `:upstream-<12hex>` | linux/amd64, arm64 | 4.09 MB | 同一次构建的旧名字，保留兼容 |

* manifest list：`sha256:6954baadb50380e82febc655c81087b314d5b13860e79d29c612c3f260b7d5a0`（两个包名同一份）
* `:upstream-<12hex>` 是构建时上游 `latest` 的 manifest digest 前 12 位（当前 `upstream-22240c07d8ce`），便于回溯二进制来源
* 体积对比（同一口径）：上游 8.08 MB / 早期「上游 + `apk upgrade`」版 11.08 MB / 本镜像 **4.09 MB**；wrt 上解包后 23.6 MB → **8.32 MB**

> GHCR 新建的包默认是 **private**，首次推送后要到 package settings 里把可见性改成 Public，否则没有凭据的宿主机拉不到（报 `unauthorized`）。

## 镜像里有什么

```text
/usr/bin/ssserver                     8.3 MB  静态链接，唯一可执行文件
/etc/passwd                           0.4 KB  上游的，`-a nobody` 需要
/etc/shadowsocks-rust/config.json     0.2 KB  上游默认配置
```

没有 shell、没有 libc、没有包管理器、没有时区库、没有 CA 证书。代价：

* **日志时间戳是 UTC**（跟上游镜像一样，它也没有 `/usr/share/zoneinfo`）；不想要时间戳就加 `--log-without-time`；
* 容器内无法 `sh`/`exec` 进去排查（要看状态就用 `docker logs` / `docker inspect`；要调试就临时跑上游镜像）。

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

对比（2026-10-16）：上游镜像 21 条 → 本镜像 0 条（`Results: None`，没有可扫目标，Arcane 里显示 0）。

## 部署

**注意**：镜像入口点是 `/usr/bin/ssserver` 本身（没有上游那个 shim），所以 `command` 里**不要再写 `ssserver`**，直接跟参数：

```yaml
services:
  shadowsocks:
    image: ghcr.io/viogus/shadowsocks-server-rust:latest
    container_name: shadowsocks-server
    network_mode: host
    restart: always
    environment:
      - TZ=Asia/Shanghai          # scratch 里没有时区库，这个变量不生效（日志仍为 UTC）
    command: -U -s 0.0.0.0:24000 -m chacha20-ietf-poly1305 -k <password>
```

等价的 `docker run`：

```bash
docker run -d --name shadowsocks-server --network host --restart always \
  -e TZ=Asia/Shanghai \
  ghcr.io/viogus/shadowsocks-server-rust:latest \
  -U -s 0.0.0.0:24000 -m chacha20-ietf-poly1305 -k <password>
```

从上游镜像迁移时，只需删掉命令开头的 `ssserver`（客户端参数完全不变）。

## 更新

`.github/workflows/build-shadowsocks.yml` 负责自动重建：

* **触发**：`docker/shadowsocks/**` 或该 workflow 本身的 push、每周一 `03:37 UTC` 定时、`workflow_dispatch` 手动；
* **构建**：`docker buildx`（linux/amd64 + linux/arm64），`pull: true` 保证每次都重新解析上游 `latest`，上游换了二进制就自动跟随；Dockerfile 里没有 `RUN`，不需要缓存策略；
* **标签**：两个包名各推 `latest` 和 `upstream-<上游 digest 前 12 位>`；
* **可见性**：两个 GHCR 包都已存在且为 public，CI 用 `GITHUB_TOKEN` 推送既不会新建包也不会改可见性。

手动重建（本地，含 `1.25.0` 版本标签）：见上面「构建」。上游是否重建过，用 `docker manifest inspect ghcr.io/shadowsocks/ssserver-rust:latest` 对比 digest 即可。
