# snell-server 底座方案对比（Tiny Core vs Alpine vs scratch）

用 [Tiny Core Linux](http://tinycorelinux.net/) 做底座重做了一份 snell-server 镜像，并和
Alpine 底座、以及现网 `scratch` 底座逐层实测对比体积。

**一句话结论：Tiny Core 精简底座（6.79 MB 解压 / 2.67 MB 压缩，自带 glibc + libstdc++ +
busybox）比 `alpine:3.20` 自身还小，成镜像后只有 Alpine 方案的一半左右；和现网 scratch
镜像体积基本持平（±1.2%），但多了一个完整可调试的 busybox 用户态。**

> **现状（2026-10）**：生产 `docker/snell/Dockerfile` 已经切换成这套方案——Tiny Core 精简
> 底座 + **musl 静态 entrypoint**，并且 amd64/arm64/armv7 三个平台都从 Tiny Core 取 rootfs
> （arm64/armv7 走 piCore 树莓派整盘镜像）。本目录保留四个变体与逐层实测数据，作为选型依据
> 和复现记录；体积总表见 [`../README.md`](../README.md#底座与体积tiny-core--musl实测)。

| linux/amd64，snell v5.0.1 | 压缩体积 | 相对 Alpine 方案 |
|---|---|---|
| 现网 Dockerfile（scratch 底座 + glibc 静态 entrypoint） | 3.899 MB | — |
| **Tiny Core 精简底座（本变体，musl 静态 entrypoint）** | **3.853 MB** | **54.5%** of alpine-glibc |
| Tiny Core 完整底座 | 4.955 MB | 70.1% |
| Alpine 底座 + 一份 Debian glibc | 7.069 MB | 100% |

| linux/amd64，snell v6.0.0rc2 | 压缩体积 | 相对 Alpine 方案 |
|---|---|---|
| 现网 Dockerfile | 4.038 MB | — |
| **Tiny Core 精简底座** | **3.991 MB** | **68.9%** of alpine-gcompat / 55.4% of alpine-glibc |
| Tiny Core 完整底座 | 5.092 MB | 87.9% / 70.7% |
| Alpine + gcompat 垫片 | 5.790 MB | 100% |
| Alpine + 一份 Debian glibc | 7.206 MB | 124% |

---

## 1. 为什么 snell 的底座不是随便挑的

官方 snell 是 **glibc 二进制**，这一点决定了所有底座方案：

| 版本 | 形态 | 运行要求 |
|---|---|---|
| v5 | `file` 显示 "statically linked"，**没有 PT_INTERP、没有 dynamic section**，但运行时第 52 个 syscall 就是 `open("/lib64/ld-linux-x86-64.so.2")`（aarch64 为 `/lib/ld-linux-aarch64.so.1`），随后按普通 glibc 程序加载 `libstdc++ / libm / libgcc_s / libc` | 磁盘上必须有**完整 glibc + libstdc++**；该路径字符串是运行时构造的，`strings` 搜不到 |
| v6 | 普通动态链接，`PT_INTERP = /lib64/ld-linux-x86-64.so.2`（amd64）/ `/lib/ld-linux-aarch64.so.1`（arm64） | 同上 |

由此得到三个硬事实（都实测过）：

1. **musl 直接跑不了 snell**：alpine:3.20 里 `apk add libstdc++ libgcc` 后运行 v6 会报
   `Error relocating ...: __strdup: symbol not found` / `__vfprintf_chk: symbol not found` /
   `makecontext: symbol not found`。
2. **gcompat 只能救 v6**：加了 gcompat 后 v6 能跑，v5 会报
   `ld-linux-x86-64.so.2: snell-server: Not a valid dynamic program`（gcompat 的 loader
   垫片只处理带 PT_INTERP 的普通动态程序，v5 是 static-pie）。
3. **Tiny Core 天生合适**：Tiny Core 的系统 libc 就是 **glibc**，而且基础 rootfs 里已经带了
   `libstdc++.so.6.0.33` + `libgcc_s.so.1` ⇒ 不需要再叠 glibc，v5/v6 都能原生跑。

## 2. 变体清单

| 文件 | 底座 | 支持版本 | 架构 |
|---|---|---|---|
| `variants/Dockerfile.tinycore` | Tiny Core（amd64 = CorePure64 16.2；arm64 = piCore64 16.0） | v4/v5/v6 | amd64, arm64 |
| `variants/Dockerfile.alpine-glibc` | `alpine:3.20` + 一份 Debian glibc | v4/v5/v6 | amd64, arm64, arm/v7 |
| `variants/Dockerfile.alpine-gcompat` | `alpine:3.20` + gcompat/libstdc++/libgcc | 仅 v6（v4/v5 构建即报错） | amd64, arm64 |
| `variants/Dockerfile.scratch` | `scratch`（= 现网 Dockerfile 的等价重现，但换用 musl 静态 entrypoint） | v4/v5/v6 | amd64, arm64, arm/v7 |
| `measure-image-size.py` | — | — | 量体积的工具，见 §5 |

四个变体都复用同一份 `docker/snell/entrypoint.c`（构建期注入 `SNELL_VERSION`），env 变量、
配置生成逻辑与现网镜像完全一致，可以直接替换使用。

Tiny Core 变体额外提供 `TC_SLIM=1`：在完整 rootfs 上再精简一层（去掉 e2fsprogs/udev/Tiny
Core 自家的 tce* 工具、gconv、libz/libsysfs/libffi 等容器用不到的库），**保留 busybox 的
~130 个 applet 软链**（awk/sed/grep/tar/wget/vi/find/netstat/nslookup…，实测全部可用）。

## 3. 实测：底座/叠加层大小（解压 MB / 压缩 MB）

单平台口径，逐层量（`docker save` + OCI blob）：

| 层 | linux/amd64 | linux/arm64 |
|---|---|---|
| Tiny Core 完整 rootfs（去掉 /lib/modules、firmware） | 9.373 / 3.774 | 11.030 / 4.018 |
| **Tiny Core 精简 rootfs（`TC_SLIM=1`）** | **6.789 / 2.673** | **6.512 / 2.414** |
| `alpine:3.20` 自身 | 7.717 / 3.462 | 8.686 / 3.903 |
| Debian glibc 叠加层（alpine-glibc 用） | 5.613 / 2.426 | 4.914 / 2.067 |
| gcompat + musl libstdc++/libgcc（alpine-gcompat 用） | 2.881 / 1.009 | 3.057 / 0.981 |
| snell v5.0.1 二进制 | 1.191 / 1.160 | 1.251 / 1.199 |
| snell v6.0.0rc2 二进制 | 2.722 / 1.297 | 2.571 / 1.303 |
| entrypoint（musl 静态，本变体） | 0.042 / 0.021 | 0.065 / 0.028 |
| entrypoint（glibc 静态，现网 Dockerfile） | 0.678 / 0.313 | — |

读法：

* **Tiny Core 的完整用户态（glibc + libstdc++ + busybox + 100 多个 applet + /etc）压缩后
  只有 2.673 MB，比"裸一份 Debian glibc 库"（2.426 MB）只多 0.25 MB。**
* Alpine 底座的成本是 `alpine 自身 3.462` + `必须再来一份 glibc 2.426` = 5.888 MB，是 Tiny
  Core 精简底座的 2.2 倍——musl 用户态在跑 glibc 二进制时是纯冗余。
* 现网 scratch 底座其实只有 glibc 库 + snell（6.803 MB 解压 / 3.586 MB 压缩，其中
  `5.613 + 1.191 = 6.804` 与 alpine-glibc 的两个层完全对得上，见 §5 校验）。
* 顺带一个发现：**现网 entrypoint 用 `gcc -static`（glibc）编出来有 0.678 MB / 0.313 MB
  压缩，换成 musl 静态只有 0.042 MB / 0.021 MB**，光这一项就省 0.29 MB —— 相当于整镜像的
  7%，比换底座省得还多。

## 4. 实测：整镜像大小

格式：压缩 MB（解压 MB）。

### linux/amd64

| 方案 | snell v5.0.1 | snell v6.0.0rc2 |
|---|---|---|
| 现网 Dockerfile（scratch + glibc 静态 entrypoint） | 3.899 (7.480) | 4.038 (9.012) |
| scratch 变体（scratch + musl 静态 entrypoint） | 3.606 (6.845) | 3.746 (8.376) |
| **tinycore-slim（`TC_SLIM=1`）** | **3.853 (8.022)** | **3.991 (9.553)** |
| tinycore（完整 rootfs） | 4.955 (10.606) | 5.092 (12.137) |
| alpine-glibc | 7.069 (14.563) | 7.206 (16.094) |
| alpine-gcompat | 不支持 v5 | 5.790 (13.363) |

### linux/arm64

| 方案 | snell v5.0.1 | snell v6.0.0rc2 |
|---|---|---|
| scratch 变体（musl 静态 entrypoint） | 3.295 (6.229) | 3.399 (7.549) |
| **tinycore-slim（piCore64）** | **3.642 (7.829)** | **3.746 (9.148)** |
| tinycore（piCore64 完整 rootfs） | 5.246 (12.346) | 5.350 (13.666) |
| alpine-glibc | 7.197 (14.916) | — |
| alpine-gcompat | 不支持 v5 | 6.215 (14.379) |

## 5. 怎么量的 / 校验

```bash
python3 docker/snell/variants/measure-image-size.py <img.tar>
```

* 用 `docker save` 出 OCI layout，逐层取 blob：**压缩大小 = blob 字节数**（registry 上真正
  传输的量），**解压大小 = blob 尾部 gzip ISIZE**（落盘量）。
* 不要用 `docker images` 的 SIZE：containerd 镜像仓库下它把多平台 manifest 一起算进去了
  （例如 `alpine:3.20` 显示 25.8MB，单平台其实只有 ~3.5MB 压缩）。
* 构建都加 `--platform` + `--provenance=false`，避免 attestation 干扰测量。
* **交叉校验**：(a) scratch 的 libs+snell 层 6.803 MB ≈ alpine-glibc 的 glibc 层 5.613 +
  snell 层 1.191 = 6.804 MB；(b) 和 GHCR 上现网 `latest` 对得上：registry 报 **3.53 MB**
  （arm64），本次 arm64 scratch 等价重建 = 3.295（musl entrypoint）+ 0.292（glibc 静态
  entrypoint 的差额）= 3.587 MB，偏差 1.6%。
* **功能冒烟**（每个变体 × amd64/arm64）：`docker run -d -e PORT=9200 -e PSK=…` 后
  `status=running`、日志出现 `Start snell server on 0.0.0.0:9200`、`busybox netstat -ltn`
  能看到 `:9200` LISTEN、banner 版本正确。4 个 Tiny Core 镜像（完整/精简 × v5/v6）×
  2 架构共 8 个组合全部通过；amd64 经 binfmt/qemu 运行，arm64 原生。

## 6. 怎么构建

```bash
# Tiny Core（精简版，推荐）
docker build -f docker/snell/variants/Dockerfile.tinycore docker/snell \
  --build-arg SNELL_VERSION=5.0.1 --build-arg TC_SLIM=1 -t snell-server:tinycore-slim

# Tiny Core（完整 rootfs）
docker build -f docker/snell/variants/Dockerfile.tinycore docker/snell \
  --build-arg SNELL_VERSION=6.0.0rc2 -t snell-server:tinycore

# Alpine 对照
docker build -f docker/snell/variants/Dockerfile.alpine-glibc docker/snell \
  --build-arg SNELL_VERSION=5.0.1 -t snell-server:alpine-glibc
docker build -f docker/snell/variants/Dockerfile.alpine-gcompat docker/snell \
  --build-arg SNELL_VERSION=6.0.0rc2 -t snell-server:alpine-gcompat

# 底座来源可换（默认官方，国内可指向镜像站）
--build-arg SNELL_BASE_URL=https://dl.nssurge.com/snell
--build-arg TC_MAJOR=16 --build-arg PICORE_VERSION=16.0.0
```

用法与现网镜像完全一致（`PORT` / `PSK` / `MODE` / `DNS_IP_PREFERENCE` / `IPV6` / `OBFS` /
`OBFS_HOST` / `CONF`，或挂载 `snell-server.conf` + `command: -c …`），见上一级 README。

## 7. 已知限制（选它之前先读）

1. **Tiny Core 不是通用发行版**：镜像里没有 apk/apt、没有 `/etc/ssl`、没有 CA 证书包、
   没有 curl/openssl。snell 当前不需要这些，但**将来要在镜像里做别的事就得改 Dockerfile**。
   精简版还删掉了 Tiny Core 的 `tce*` 包管理脚本，镜像不可运行时扩展。
2. **架构覆盖**：Tiny Core 只有 x86_64（CorePure64）与树莓派（piCore）两种 rootfs，**没有
   通用 armv7** ⇒ 本变体不支持 `linux/arm/v7`（现网 v4/v5 支持）。若要保留 armv7，只能继续
   用 scratch 或 alpine 变体。
3. **arm64 底座是树莓派镜像**：piCore64 只以 40 MB 整盘镜像（`.img.gz`）分发，rootfs 是启动
   FAT 分区里的 `rootfs-piCore64-<ver>.gz`，Dockerfile 里靠 MBR 分区表 + `mcopy` 取出来（不
   依赖 loop 挂载）。构建时要多下一个 40 MB 的镜像；amd64 只需 16.8 MB 的 `corepure64.gz`。
   另外 piCore 版本落后于 CorePure64（16.0 vs 16.2）。
4. **amd64 需要补 loader 路径**：Tiny Core 把加载器放在 `/lib/ld-linux-x86-64.so.2`，而
   x86-64 glibc 约定与 snell 实际引用的都是 `/lib64/ld-linux-x86-64.so.2`，镜像里补了这个
   软链（arm64 的 `/lib/ld-linux-aarch64.so.1` 本来就是标准路径）。
5. **底座维护方是 Tiny Core 上游**（社区发行版，非 glibc 官方），安全更新要自己跟。
6. **entrypoint 换了编译器**：本变体用 musl 静态编译（体积 0.042 MB，功能与现网 glibc 静态
   版一致，已冒烟验证）。若坚持 glibc 静态，改回现网那两行即可（+0.29 MB 压缩）。
7. **本变体尚未接进 CI**：`docker/snell/Dockerfile` 与 `build-snell.yml` 未改动，现网
   `ghcr.io/viogus/snell-server` 不受影响。是否切换、armv7 怎么保留属于产品决策。
