# contacts-editor

macOS 通讯录（Contacts）批量编辑 CLI 工具，用 Swift 编写。

- **拼音注音**：为中文联系人自动生成 `phoneticFamilyName` / `phoneticGivenName`，支持复合姓与多音姓。
- **电话规范化**：为中国大陆手机号补全 `+86` 前缀。
- **群组过滤**：可只处理指定群组内的联系人。
- **预览优先**：默认 dry-run，只有 `--write` 才写回通讯录。

## 安装 / 构建

```bash
swift build -c release
# 产物: .build/release/cli
```

首次运行会请求通讯录访问权限。如被拒绝，前往
系统设置 → 隐私与安全性 → 通讯录 手动授权。

## 用法

```
contacts-editor pinyin                  拼音 dry-run（预览）
contacts-editor pinyin --write          拼音执行（写回）
contacts-editor pinyin --group <name>   拼音，仅处理指定群组
contacts-editor phone                   电话 dry-run（预览）
contacts-editor phone --write           电话执行（写回）
contacts-editor phone --group <name>    电话，仅处理指定群组
contacts-editor list groups             列出所有群组
```

`--write` 是唯一的副作用闸门；不加则只打印将要发生的变更。

## 功能架构图

```
┌─────────────────────────────────────────────────────────────┐
│                     contacts-editor (CLI)                     │
│                        Sources/cli/main.swift                 │
└─────────────────────────────────────────────────────────────┘
        │
        │ 1. 解析参数: subcommand + --write + --group
        │ 2. CNContactStore.requestAccess (通讯录授权)
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│                     子命令分发 switch                        │
└───────────────────────────────────────────────────────────┘
   │                     │                      │
   ▼                     ▼                      ▼
┌────────┐          ┌────────┐          ┌──────────────┐
│ pinyin │          │ phone  │          │ list groups  │
└────────┘          └────────┘          └──────────────┘
   │                     │                      │
   │ enumerateContacts   │ enumerateContacts    │ store.groups
   │ (+group predicate)  │ (+group predicate)   │
   ▼                     ▼                      ▼
┌──────────────────────────────────┐    ┌──────────────┐
│  computePhoneticChange()         │    │ 打印群组名    │
│  ┌────────────────────────────┐  │    └──────────────┘
│  │ containsCJK   (CJK 检测)   │  │
│  │ splitName     (姓名拆分)   │  │       ┌──────────────────────┐
│  │  ├ splitCompoundSurname    │  │       │ normalizeChinesePhone│
│  │  │   欧阳/司马/诸葛…       │  │       │  11位 + 1开头 + 纯数字│
│  │ surnamePinyin              │  │       │        ↓             │
│  │  ├ lookupMultiToneSurname  │  │       │     "+86 <num>"      │
│  │  │   曾=Zeng 解=Xie…      │  │       └──────────────────────┘
│  │  └ toPinyin (CFStringTransform)│                │
│  │ givenNamePinyin            │  │                │
│  └────────────────────────────┘  │                │
└──────────────────────────────────┘                │
        │                                            │
        └──────────────┬─────────────────────────────┘
                       ▼
          ┌────────────────────────────┐
          │  --write ?                  │
          │   否 → 打印预览 (dry-run)   │
          │   是 → CNSaveRequest.update │
          │        store.execute        │
          └────────────────────────────┘
                       │
                       ▼
              成功 N / 失败 M
```

## 分层

| 层 | 路径 | 职责 |
|----|------|------|
| `ContactsEditorCore` | `Sources/ContactsEditorCore/core.swift`、`phone.swift` | 纯逻辑：CJK 检测、姓名拆分、拼音转换、电话规范化。无 IO，可单测。 |
| `cli` | `Sources/cli/main.swift` | 命令行解析、通讯录授权、读写、dry-run 门控。 |
| `Tests` | `Tests/ContactsEditorCoreTests/pinyin_tests.swift` | Core 层单元测试。 |

## 拼音处理细节

- **CJK 检测**：主区（U+4E00–U+9FFF）+ 扩展 A（U+3400–U+4DBF）+ 兼容表意（U+F900–U+FAFF）。
- **复合姓**：欧阳、司马、诸葛 等 22 个，按长度优先匹配（"欧阳" 先于 "欧"）。
- **多音姓字典**：曾=Zeng、解=Xie、单=Shan… 覆盖 `CFStringTransform` 的默认错读。
- **姓名拆分**：`familyName` 为空时从 `givenName` 首字推断姓氏。
- **转换**：`CFStringTransform` 转拉丁 + 去声调，合并同名多音节。

## 电话处理细节

- 去除空格、横线、括号后判断。
- 条件：11 位、`1` 开头、纯数字。
- 已有 `+` 前缀的号码跳过。
- 输出格式：`+86 <11位号码>`。
