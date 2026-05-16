# contacts-editor: 重构为多子命令工具 + 电话号码标准化

## 目标

将 `contacts-pinyin` 重构为通用通讯录编辑工具 `contacts-editor`，支持多个子命令。新增电话号码标准化功能：为中国大陆手机号自动添加 `+86` 国际前缀。

## CLI

```
contacts-editor                               # 显示帮助
contacts-editor pinyin                        # 拼音 dry-run
contacts-editor pinyin --write                # 拼音执行
contacts-editor pinyin --group "工作"          # 拼音分组过滤
contacts-editor phone                         # 电话 dry-run
contacts-editor phone --write                 # 电话执行
contacts-editor phone --group "工作"           # 电话分组过滤
contacts-editor list groups                   # 列出所有群组名称
```

默认 dry-run，需显式 `--write` 才写入。无参数时显示 help。

退出码: 0=成功，1=授权拒绝，2=读取/参数错误。

## 项目结构

包名和模块名重命名:

```
contacts-pinyin/                              # 目录名保留
├── Package.swift                              # name: "contacts-editor"
├── Sources/
│   ├── ContactsEditorCore/                    # rename from ContactsPinyinCore
│   │   ├── core.swift                         # pinyin 逻辑 (现有，保留)
│   │   └── phone.swift                        # NEW: 电话检测/标准化
│   └── cli/
│       └── main.swift                         # 子命令 dispatch
└── Tests/
    └── ContactsEditorCoreTests/               # rename from ContactsPinyinCoreTests
        ├── pinyin_tests.swift                 # rename from Tests.swift
        └── phone_tests.swift                  # NEW: 电话测试
```

二进制安装到 `/usr/local/bin/contacts-editor`。

## 电话号码检测规则

**判定逻辑（option B）：**

1. 预处理：去掉空格、横线、括号 `[\s\-\(\)]`
2. 以 `+` 开头 → 跳过（已有国际前缀）
3. 11 位数字、以 `1` 开头 → 中国大陆手机号 → 加 `+86`
4. 其他长度/格式 → 跳过（座机、短号、非中国号码、服务号等）

**返回值：**

- 需要更新：返回 `"+86 <原始号码>"`，如 `"13800138000"` → `"+86 13800138000"`
- 不需要更新：返回 `nil`

**不在电话号码中保留现有格式中的空格/横线。**

## 联系人更新策略

- 遍历所有电话号码字段 (`CNContactPhoneNumbersKey`)
- `CNLabeledValue<CNPhoneNumber>` 中的 `value.stringValue` 为原始号码
- 生成新号码后，通过 `CNMutableContact.phoneNumbers` 更新
- 和拼音子命令同样：dry-run 预览，`--write` 写入
- 每个联系人单独 `CNSaveRequest`，单个失败记录 stderr 继续

## 代码接口

```swift
// phone.swift - ContactsEditorCore

/// Normalize a Chinese mobile phone number by prepending +86.
/// Returns the normalized number, or nil if no change needed.
public func normalizeChinesePhone(_ number: String) -> String?
```

## 测试

- 11 位 1 开头无前缀 → 加 +86
- 含空格/横线格式的 11 位 → 加 +86，返回 `"+86 <原始>"` 
- 已有 `+86` → nil
- 已有 `+1` → nil
- 非 11 位（座机）→ nil
- 12 位 → nil
- 含非数字 → nil
- 空字符串 → nil

## 错误处理

- 授权拒绝：exit 1
- 读取失败：exit 2
- 单个联系人更新失败：stderr + continue
- 汇总：`成功 N / 失败 M`

## list groups 子命令

只读，无需 `--write`。列出所有群组名称。

```
$ contacts-editor list groups
工作
家人
朋友
```

通过 `CNContactStore.groups(matching:)` 获取。退出码 0。

## 边界情况

- 联系人无电话号码 → 跳过
- 多个电话号码 → 分别判断
- 已存为 `+86 13800138000` → 幂等，跳过
- 已存为 `+8613800138000`（无空格）→ 跳过（`+` 开头命中）
