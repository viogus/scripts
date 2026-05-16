# contacts-pinyin: macOS 通讯录中文名自动填充拼音

## 目标

给 macOS 通讯录中的中文联系人自动填充 phoneticGivenName / phoneticFamilyName 字段，使系统按姓氏拼音排序。

## 技术选型

- **语言：** Swift（`swift` 解释执行或 `swiftc` 编译）
- **系统框架：** Contacts.framework + CoreFoundation
- **拼音：** `CFStringTransform` + 内置多音姓氏表 + 复姓列表
- **零额外依赖**

## 项目结构

SPM 项目，三个 target：

```
contacts-pinyin/
├── Package.swift                          # swift-tools-version:5.9
├── Sources/
│   ├── ContactsPinyinCore/core.swift      # 纯逻辑，可测试
│   └── cli/main.swift                     # CLI 入口，Contacts.framework 集成
└── Tests/
    └── ContactsPinyinCoreTests/Tests.swift # 自定义测试 runner，不依赖 XCTest
```

测试通过 `swift run ContactsPinyinCoreTests` 运行（因命令行工具不含 XCTest）。
编译后二进制安装到 `/usr/local/bin/contacts-pinyin`。

## 数据流

```
请求授权 → CNContactFetchRequest 获取全部联系人
→ 检测中文名（含 CJK 字符）
→ 拆分姓/名（复姓感知）
→ 姓氏查多音表，未命中用 CFStringTransform
→ 名字用 CFStringTransform
→ 对比现有 phonetic 字段
→ 有变化则加入 CNSaveRequest 批量
→ dry run 模式只打印预览，不写入
```

## 中文名检测

检查 `familyName` 和 `givenName` 是否包含 CJK 文字：

- CJK 统一表意文字主块（U+4E00–U+9FFF）
- CJK 扩展 A（U+3400–U+4DBF）
- CJK 兼容表意文字（U+F900–U+FAFF）

任一字段含上述范围字符即判定为中文联系人。

仅处理人名，不处理 organizationName。

## 姓/名拆分

- 无 familyName：givenName 首字为姓，其余为名
- 有 familyName 且 givenName 非空：familyName 直接作为姓
- 有 familyName 且 givenName 为空且 familyName 长度 > 1：推断为完整姓名存入了 familyName 字段，尝试拆分（复姓优先，否则首字为姓）
- 有 familyName 且 givenName 为空且 familyName 长度为 1：直接作为姓
- 复姓匹配：familyName 前缀命中内置复姓列表时，整个复姓为姓

复姓列表（20+）：欧阳、司马、上官、诸葛、夏侯、东方、皇甫、令狐、慕容、宇文、长孙、公孙、司徒、尉迟、淳于、太史、申屠、端木、万俟、独孤、南宫、拓跋

## 拼音转换

两步走：

```swift
CFStringTransform(s, nil, kCFStringTransformToLatin, false)   // 汉字→带声调拼音
CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)  // 去声调
```

姓氏优先查内置多音姓氏表（30+ 姓），命中用表值，未命中走 CFStringTransform。名字统一走 CFStringTransform。

拼音格式：首字母大写，姓和名分开（如 `Zhao Wei`），不拼接。

CFStringTransform 在音节间插入空格。输出前用正则 `(?<=[a-z]) (?=[a-z])` 连接拼音音节间的空格，保留英文单词边界（如 `Tom 王` → `Tom wang`，`小明` → `xiaoming`）。

`ü` 保留，不转 `v`。

## CLI

```bash
./contacts-pinyin              # 正式执行
./contacts-pinyin --dry-run    # 预览模式，只读
./contacts-pinyin --group "工作"  # 仅处理指定群组
```

Dry run 输出格式：列出每个联系人的新旧拼音对照，明确标注哪些字段会变化。汇总更新数量。

退出码：0=成功或无可更新联系人, 1=授权拒绝, 2=读取失败/群组未找到, 3=批量写入失败

## 更新策略

覆盖模式：已有 phonetic 字段的联系人也会重新生成（用户确认的选择）。

幂等：重复运行安全。值不变时不写入 CNSaveRequest。

## 错误处理

- 授权拒绝：提示去「系统设置 → 隐私 → 通讯录」授权，exit 1
- 所有更新合并为单个 `CNSaveRequest` 批量提交。批量失败则整体 exit 3
- 汇总：`成功 N / 失败 M`（跳过项不单独计数，因为没有变化则不会进入保存流程）

## 边界情况

- 无姓氏（公司名、单名）：跳过
- 名字含英文/emoji：仅拼音化中文部分
- 大量联系人（>5000）：CNContactFetchRequest 分批处理，不 OOM
- 多音字名字：CFStringTransform 默认读音，可接受
