# TimescaleDB 精简镜像：Tiny Core Linux vs Alpine

`docker/timescaledb/Dockerfile` 就是本仓库现在构建并推送到 `ghcr.io/viogus/timescaledb:latest-pg18` /
`:2.30.0-pg18`（amd64 + arm64）的生产镜像（CI：`.github/workflows/build-timescaledb.yml`），
底座是 Tiny Core Linux。下表的另外两项是比较对象。

运行时需要预加载扩展：

```yaml
command: ["postgres", "-c", "shared_preload_libraries=timescaledb"]
```

以 **PostgreSQL 18.6 + TimescaleDB 2.30.0** 为内容，三种底座的镜像体积：

| 镜像 | 底座 | 层数 | 压缩 | 解压 | 相对 `viogus/timescaledb` |
|---|---|---|---|---|---|
| `ghcr.io/viogus/timescaledb:2.30.0-pg18`（你现在的） | alpine + 全套构建选项 | 11 | **117.53 MiB** | 310.46 MiB | — |
| `Dockerfile.alpine-lean`（对照） | alpine:3.24 | 8 | **23.52 MiB** | 79.43 MiB | **−80.0%** |
| `Dockerfile`（Tiny Core） | Tiny Core Linux | 12 | **22.04 MiB** | 72.83 MiB | **−81.2%（约 1/5.3）** |

> 口径：`docker save` 出的 OCI 归档，压缩 = 各层 blob 实际大小，解压 = 各层 tar 大小，由 `measure-image-size.py` 统计。
> 实测平台 linux/arm64（amd64 见文末）。两套方案都已跑通冒烟：18.6 + timescaledb 2.30.0 + hypertable + 压缩/连续聚合，
> 以及「旧 Alpine/musl 数据目录（`en_US.utf8`）直接启动」的升级回归（见「从旧镜像升级」一节）。

## 架构支持

| 平台 | 状态 | 底座 |
|---|---|---|
| `linux/amd64` | ✅ CI 构建并推送 | CorePure64 16.x 通用 rootfs |
| `linux/arm64` | ✅ CI 构建并推送 | piCore64 16.x（aarch64 只以树莓派整盘镜像分发，rootfs 在启动分区里） |
| 其它 | ❌ 构建即报错 | Tiny Core 16.x 只有 x86_64 / aarch64 / armhf / x86 四种 rootfs |

Tiny Core 另外两种 rootfs（`armhf`、`x86`）都是 32 位，装不下这条栈：PostgreSQL 18 与
TimescaleDB 2.30 都以 64 位为目标（Timescale 只发 x86_64 / aarch64 的包；Debian 已把
x86-32 移出发布架构，PostgreSQL 社区也在讨论放弃 32 位）。需要 32 位、或者
riscv64/ppc64le/s390x 这类 Tiny Core 没有的架构时，走 musl 路线：

```sh
./build.sh alpine-lean <arch>    # Dockerfile.alpine-lean；能否成功取决于上游是否支持该架构
```

CI（`.github/workflows/build-timescaledb.yml`）按平台矩阵在**原生** runner 上构建，再用 `imagetools`
合并成一个多架构 manifest：

| 平台 | runner | 实测耗时 |
|---|---|---|
| `linux/amd64` | `ubuntu-24.04` | 4m02s |
| `linux/arm64` | `ubuntu-24.04-arm` | 3m03s |
| 合并 | `ubuntu-24.04`（merge job） | 22s |

两个平台都钉在 24.04 LTS 上（不用 `ubuntu-latest`，免得 label 迁到 Ubuntu 26 后环境漂移）；
所有 action 都用 node24 的大版本（checkout@v7、upload-artifact@v7、download-artifact@v8、
login-action@v4、setup-buildx-action@v4、build-push-action@v7）。

每个平台 `push-by-digest` 后，**在同一个原生 runner 上把这个 digest 拉回来跑一遍
`smoke-timescaledb.sh`**（起库 → `CREATE EXTENSION timescaledb` → hypertable → 插查），冒烟通过
才上传 digest；merge job 用 `docker buildx imagetools create` 合成 `:latest-pg18` /
`:2.30.0-pg18`。冒烟失败则该平台没有 digest，merge job 拿不到它 ⇒ 不会发布坏镜像。

发布产物实测：amd64 **21.468 MiB**、arm64 **21.280 MiB**（各 12 层），层大小与本地构建、以及
多次 CI 构建之间**逐层一致**（config 里带时间戳，所以 manifest / index 的 digest 每次构建都会变；
可复现的是层本身）。两个平台的冒烟都在 CI 的**原生** runner 上通过 —— arm64 在
`ubuntu-24.04-arm`、amd64 在 `ubuntu-24.04`，输出都是 `服务器版本 18.6 / timescaledb 2.30.0 /
25 行 / 1 chunk / PASS`。

> 旧方案（单 job 里用 QEMU 同时构建两个平台）已废弃：52m46s 仍未编完，且本机已证明 QEMU
> 模拟下 postgres 编译会随机段错误。

## 关键结论

1. **省下的 96 MiB 里，换底座只占 1.4 MiB**。真正的大头是构建选项：
   | 去掉的东西 | 压缩体积 | 说明 |
   |---|---|---|
   | LLVM JIT | **58.76 MiB** | `/usr/lib/libLLVM.so.21.1` 单文件（156.44 MiB 原始） |
   | LLVM bitcode | **12.22 MiB** | `/usr/local/lib/postgresql/bitcode/*.bc` |
   | ICU | **13.98 MiB** | `icudt78l.dat` 12.18 + ICU 库 1.80 |
   | libxml2 / libxslt / LDAP / krb5 / libcurl / liburing | ≈ 8 MiB | `/usr/lib`、`/usr/share` |
   | PL/Perl、PL/Python、PL/Tcl | ≈ 0 | 见下，本来就用不了 |
   | **合计** | **≈ 93 MiB** | 占原镜像 **79%** |

2. **PL/Perl、PL/Python、PL/Tcl 在你现在的镜像里是坏的**：镜像里有 `plperl.so` / `plpython3.so` / `pltcl.so`，但全盘找不到 `libperl.so` / `libpython3.so` / `libtcl.so`，也没有 perl/python3/tclsh 解释器 ⇒ `CREATE EXTENSION plperl` 之类必然失败。精简版直接 `--without-perl --without-python --without-tcl`，**不构成功能损失**。

3. **Tiny Core 底座本身就值 1.4 MiB**（alpine:3.24 单平台 3.99 MiB → Tiny Core 精简后 2.57 MiB），而且 Tiny Core **自带 glibc 2.40 + libstdc++**，容器里因此有完整的 glibc 语义（locale、NSS、`getent` 行为等和 Debian 一致），代价是必须自己补几个文件（见「取舍」）。

## 体积账：117.53 MiB 花在哪

你现在的镜像逐层（arm64）：

| 层 | 压缩 | 解压 | 内容 |
|---|---|---|---|
| 0 | 3.99 | 8.53 | alpine:3.24 底座 |
| 2 | 0.81 | 1.95 | gosu |
| 4 | **107.58** | **276.36** | postgres 18.6 编译产物（含 libLLVM 58.76 + bitcode 12.22 + ICU 12.18 + 企业特性库） |
| 9 | 1.81 | 3.64 | timescaledb .so |
| 10 | 3.31 | 19.88 | timescaledb 历史版本 SQL（2.30.0 之前的 upgrade 脚本） |
| 其余 6 层 | 0.03 | 0.07 | 环境变量/入口脚本等 |

同一路径的「表观大小 → 单独打层 gzip 成本」（arm64，`measure-composition.sh`）：

| 路径 | 你的镜像 | Tiny Core 版 |
|---|---|---|
| `/usr/local/bin` | 20.32 → 7.63 | 19.72 → 7.37 |
| `/usr/local/lib/postgresql` | 36.49 → 16.23 | 12.13 → 3.52 |
| ↳ 其中 `bitcode/` | — → 12.22 | 不存在 |
| `/usr/local/share/postgresql` | 21.74 → 3.56 | 22.12 → 3.67 |
| `/usr/lib` | 184.24 → 68.72 | 3.41 → 1.02 |
| ↳ 其中 `libLLVM.so.21.1` | 156.44 → 58.76 | 不存在 |
| `/usr/share/icu` | 31.58 → 12.18 | 不存在 |
| `/lib` | 0.78 → 0.43 | 9.36 → 3.58 |
| `/etc` | 0.50 → 0.14 | 0.03 → 0.01 |

可见 `/usr/local/bin`、`/usr/local/share/postgresql`（同一份 PG 18.6 与相同的 extension SQL）两边**几乎一模一样**，差距全部集中在 LLVM/bitcode/ICU 与企业特性库上。

两个精简变体逐路径基本一致（`/usr/local/lib/postgresql` 12.97 vs 12.91、`/usr/local/share/postgresql` 22.10 vs 22.12、`/usr/local/bin` 20.25 vs 19.72），**压缩体积差 2.24 MiB 全部来自底座与运行期库的打包方式**：
alpine-lean = alpine:3.24 底座 3.99 + apk 运行期依赖层 2.23；
tinycore = Tiny Core 底座 2.57（已含 glibc/libstdc++）+ 补的依赖 so 0.60 + locale 0.83（`C.utf8` + `en_US.UTF-8`）。

## 目录内容

```
docker/timescaledb/
├── Dockerfile               # 生产镜像：Tiny Core 底座（amd64=CorePure64 / arm64=piCore64）
├── Dockerfile.alpine-lean   # 对照：alpine:3.24 底座 + 同样的精简构建选项
├── build.sh                 # ./build.sh tinycore|alpine-lean [amd64 arm64]
├── smoke-timescaledb.sh     # CREATE EXTENSION/hypertable 冒烟 + en_US.utf8 升级回归 + initdb 回归
├── measure-image-size.py    # docker save 归档逐层压缩/解压
├── measure-composition.sh   # 逐路径表观大小 + 单独打层 gzip 成本
├── inspect-image.sh         # 交互式进镜像看内容
├── docker-entrypoint.sh     # 与官方 postgres 镜像一致的入口脚本
└── docker-ensure-initdb.sh
```

CI（`.github/workflows/build-timescaledb.yml`）构建 `docker/timescaledb` 上下文，产出
`ghcr.io/viogus/timescaledb:latest-pg18` 与 `:2.30.0-pg18`（amd64 + arm64）。

## 复现

```sh
cd docker/timescaledb
./build.sh tinycore                              # amd64 + arm64
./smoke-timescaledb.sh timescaledb-tinycore:arm64
docker save timescaledb-tinycore:arm64 -o /tmp/i.tar
python3 measure-image-size.py /tmp/i.tar
```

构建选项（两个变体一致）：`--prefix=/usr/local --with-openssl --with-zlib --with-lz4 --with-zstd --with-readline --without-llvm --without-icu --without-perl --without-python --without-tcl --enable-thread-safety`，`make world-bin` + `install-world-bin`（含全部 contrib）。

## 取舍（重要）

| 项 | 你的镜像 | 精简版 | 影响 |
|---|---|---|---|
| LLVM JIT | 有 | 无 | 复杂表达式编译加速没了；日常 OLTP/时序写入基本无感 |
| ICU collation | 有 | 无 | 只能 libc collation；`C.UTF-8`（UTF8 编码，非语言排序） |
| locale 数据 | `en_US.utf8` 等各种名字（musl 下其实没有排序数据） | `C.utf8` + `en_US.UTF-8`（构建期 `localedef` 编好，代价 +0.76 MiB） | 旧 musl 数据目录能直接启动；但排序语义从 musl 的 C 字节序变成真 en_US，换完建议 `REINDEX DATABASE` 一次 |
| XML / XSLT / LDAP / GSSAPI / libcurl / liburing | 有 | 无 | 用不到就无所谓；`pg_stat_statements` 等 contrib 全在 |
| PL/Perl、PL/Python、PL/Tcl | .so 在但加载不了 | 无 | 无实际损失 |
| `uuid-ossp` | 有 | 无（未链 libuuid） | 用 `gen_random_uuid()`（PG 13+ 内置）代替 |
| 扩展总数 | 61 个 | 45 个 | 差的 16 个里 14 个是 PL/Perl·Python·Tcl 相关（你镜像里本来也加载不了），真正少的只有 `uuid-ossp` 与 `xml2` |
| ca-certificates | 有 | 无（Tiny Core 无 `/etc/ssl`） | 用到 `sslmode=verify-full` 的**客户端**需自行挂载 CA |
| 用户态 | busybox + bash + coreutils | busybox + bash（`mountpoint`/`locale` 垫片；`getent` 与 `libnss-wrapper` 从 Debian 带入，随机 uid 运行同样能 initdb；无 python3） | 运维脚本注意 |
| timezone | 系统 tzdata | PG 自带 tzdata（`pg_timezone_names` 598 条） | 正常 |
| 压缩 | 原样 | 无损 | 同内容 |

## 从旧 Alpine/musl 镜像升级：locale 兼容性

**症状**（旧数据目录 + glibc 底座的小镜像），容器每 2~3 秒重启一次：

```
LOG:  invalid value for parameter "lc_messages": "en_US.utf8"
LOG:  invalid value for parameter "lc_monetary": "en_US.utf8"
LOG:  invalid value for parameter "lc_numeric": "en_US.utf8"
LOG:  invalid value for parameter "lc_time": "en_US.utf8"
FATAL:  configuration file "/var/lib/postgresql/18/docker/postgresql.conf" contains errors
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

**根因**：旧镜像是 Alpine/musl，而 **musl 不校验 locale 名**（任何 UTF-8 名字都照收），
initdb 就把 `lc_messages/lc_monetary/lc_numeric/lc_time = 'en_US.utf8'` 以及
`pg_database.datcollate/datctype = 'en_US.utf8'` 写了进去。glibc 底座只有在
`/usr/lib/locale/en_US.utf8/` 真的存在时才认这个名字，否则：

- `postgresql.conf` 里那四个 GUC 校验失败 ⇒ **启动**就 FATAL（上面那段日志）；
- 就算用命令行 GUC 盖掉这四个值，连库时还会在 `setlocale()` 上失败：

  ```
  FATAL:  database locale is incompatible with operating system
  DETAIL:  The database was initialized with LC_COLLATE "en_US.utf8",  which is not recognized by setlocale().
  HINT:  Recreate the database with another locale or install the missing locale.
  ```

**修复（已落在 Dockerfile 里）**：镜像现在带 `C.utf8` 与 **`en_US.UTF-8`** —— `C.utf8` 直接从
Debian `libc-bin` 拷，`en_US.UTF-8` 构建期用 `localedef -i en_US -f UTF-8` 现编进
`/usr/lib/locale/en_US.utf8/`（所以 `en_US.utf8` / `en_US.UTF-8` 两种写法都能命中）。
因此**由旧镜像 initdb 出来的数据目录不用改任何东西就能起**。要多带别的 locale：

```sh
docker build -f docker/timescaledb/Dockerfile docker/timescaledb \
  --build-arg LOCALES="en_US.UTF-8 de_DE.UTF-8" -t timescaledb:tinycore
```

`/usr/local/bin/locale -a` 垫片直接列 `/usr/lib/locale`，所以加了什么就报什么。代价：locale 层
从 0.07 MiB 涨到 **0.83 MiB**。

**排序语义变化（要知道）**：musl 时代 `datcollate='en_US.utf8'` 实际按 C 的字节序比较，glibc 下
是**真的 en_US 排序**。换底座后已有 text 索引建议重建一次：

```sql
REINDEX DATABASE <db>;
ALTER DATABASE <db> REFRESH COLLATION VERSION;   -- 若日志提示 collation version mismatch
```

（musl 写的库不一定记录 collation 版本，所以没警告也建议 `REINDEX` 一次；`datcollate` 是建库时
定的，想彻底回到 C 语义只能重建库。）

**临时绕过（不换镜像时）**：命令行 `-c` 的优先级高于 `postgresql.conf`，可以盖掉 conf 里的无效值：

```yaml
command: ["postgres", "-c", "shared_preload_libraries=timescaledb",
          "-c", "lc_messages=C.UTF-8", "-c", "lc_monetary=C.UTF-8",
          "-c", "lc_numeric=C.UTF-8", "-c", "lc_time=C.UTF-8"]
```

实测这样能起来（`SHOW lc_messages` = `C.UTF-8`），但**盖不掉 `pg_database.datcollate`**，
连接时仍会撞上 `database locale is incompatible with operating system` ⇒ 只够临时救急。

**回归测试**：`smoke-timescaledb.sh` 除基本冒烟外还会
① 把 conf 的四个 `lc_*` 与 `pg_database.datcollate/datctype` 改成 `en_US.utf8`、重启、再跑一次排序；
② 用 `POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8` 做一次全新 initdb（必须 UTF8 编码 + en_US.UTF-8）。
CI 两个平台的冒烟步骤跑的就是它 ⇒ 这个坑不会再回来。

## 构建期踩坑（都已落在 Dockerfile 里）

- **PG 18 源码构建必须有 perl**（tarball 也不例外），Alpine 要显式 `apk add perl`；Debian 侧由 dpkg-dev 隐式带入。
- Alpine 包名是 `lz4-libs` / `zstd-libs`（不是 `liblz4` / `libzstd`）。
- Tiny Core **没有 `/usr/lib/locale`**：glibc 下 `initdb` 报 `invalid locale settings`，`LANG=C` 又会退化成 `SQL_ASCII`。解法是从 Debian `libc-bin` 拷现成的 `/usr/lib/locale/C.utf8` ⇒ `LANG=C.UTF-8` + UTF8 编码正常（glibc 2.40 读 2.36 编的 locale 数据没有版本问题）；`en_US.UTF-8` 用编译期 `locales` 包 + `localedef` 现编，供旧 musl 数据目录使用（见上）。
- Tiny Core 没有 `mountpoint` applet，而官方 `docker-entrypoint.sh` 会调它；补 4 行垫片消除告警。
- 官方入口脚本 shebang 是 `#!/usr/bin/env bash`，Tiny Core 只有 ash ⇒ 必须部署 Debian 的 `/bin/bash`。
- 依赖闭包用 `readelf -d` 求 `DT_NEEDED`：Tiny Core 自带的 soname 一律跳过（保证 loader 与 libc 同源），缺的按 soname 拷进 `/lib`；同时**不能加 `--disable-rpath`**，否则 `/usr/local/bin` 里的工具找不到 `/usr/local/lib` 的 libpq/libecpg。
- 本机 docker.io 不可达，底座镜像需从镜像站拉取后重新打 tag。
- Tiny Core 的 busybox 没编 `getent`，官方 entrypoint 在「非 root 且 uid 不在 /etc/passwd」时要靠它判断；
  顺手从 Debian 带进 `getent` 与 `libnss-wrapper`（共 0.036 MiB），实测以 `--user 12345:0` 运行能正常 initdb 并起库
  （和官方 postgres 镜像行为一致）。

## amd64

两个 Dockerfile 都支持 amd64（走 CorePure64 rootfs，并额外补 `/lib64/ld-linux-x86-64.so.2` 软链）。本机是 Apple Silicon，
linux/amd64 只能走 colima 的 qemu-x86_64 用户态模拟，而 postgres 编译会在**随机文件**上段错误：

```
gcc: internal compiler error: Segmentation fault signal terminated program cc1
make[2]: *** [Makefile:108: tar_shlib.o] Segmentation fault (core dumped)
```

降到 `--build-arg MAKE_JOBS=2`（Dockerfile 已支持）后仍然崩，只是换了个文件 ⇒ 本机跑不完完整构建。
这是 qemu 模拟的问题，原生 x86_64 机器（含 GitHub Actions ubuntu runner）不受影响。

能测的部分都测了：

| 项 | arm64 | amd64 |
|---|---|---|
| Tiny Core 精简底座（压缩） | 2.57 MiB | **2.62 MiB**（`--target tinycore` 单独构建后 `tar \| gzip -9`） |
| 你的镜像总量（压缩） | 117.53 MiB | 119.4 MiB（比 1.016） |
| 本方案总量（压缩） | **21.280 MiB**（本地实测） | **21.469 MiB**（CI 在原生 `ubuntu-latest` 上构建的产物实测） |

底座之外是同一份源码、同一套构建选项，两个独立比例（底座 1.018、你镜像 1.016）也吻合：当时推算
amd64 落在 21.5–21.7 MiB，CI 实测 21.469 MiB，吻合。也就是说 amd64 这条路**已经由 CI 的原生
x86_64 runner 完整构建并发布**（3m59s），本机 qemu 的限制只影响本地构建，不影响产物。
