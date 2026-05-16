# contacts-pinyin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swift script that populates phoneticGivenName/phoneticFamilyName on macOS Contacts for Chinese names, using CFStringTransform + multi-tone surname table + compound surname detection.

**Architecture:** SPM project with two targets — ContactsPinyinCore (pure logic, testable) and cli (Contacts.framework integration + CLI). Single binary output installed to `/usr/local/bin/contacts-pinyin`.

**Tech Stack:** Swift 5, Contacts.framework, CoreFoundation, SPM

**Files:**
- Create: `contacts-pinyin/Package.swift`
- Create: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift`
- Create: `contacts-pinyin/Sources/cli/main.swift`
- Create: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift`

---

### Task 1: Project scaffolding

**Files:**
- Create: `contacts-pinyin/Package.swift`

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "contacts-pinyin",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "ContactsPinyinCore",
            path: "Sources/ContactsPinyinCore"
        ),
        .executableTarget(
            name: "cli",
            dependencies: ["ContactsPinyinCore"],
            path: "Sources/cli"
        ),
        .testTarget(
            name: "ContactsPinyinCoreTests",
            dependencies: ["ContactsPinyinCore"],
            path: "Tests/ContactsPinyinCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Verify build**

```bash
cd contacts-pinyin && swift build
```

Expected: builds successfully with empty source files (just needs any .swift file to exist).

- [ ] **Step 3: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: scaffold contacts-pinyin SPM project"
```

---

### Task 2: ChineseDetector — CJK character detection

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (create)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (create)

- [ ] **Step 1: Write the failing test**

In `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
import XCTest
@testable import ContactsPinyinCore

final class ChineseDetectorTests: XCTestCase {
    func testContainsCJK_withChinese_returnsTrue() {
        XCTAssertTrue(containsCJK("王小明"))
        XCTAssertTrue(containsCJK("张"))
    }

    func testContainsCJK_withMixedText_returnsTrue() {
        XCTAssertTrue(containsCJK("Tom 王"))
        XCTAssertTrue(containsCJK("Hello世界"))
    }

    func testContainsCJK_withoutChinese_returnsFalse() {
        XCTAssertFalse(containsCJK("Tom"))
        XCTAssertFalse(containsCJK(""))
        XCTAssertFalse(containsCJK("abc123"))
    }

    func testContainsCJK_withJapanese_returnsTrue() {
        // Japanese kanji overlap with CJK range — acceptable
        XCTAssertTrue(containsCJK("東京"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter ChineseDetectorTests 2>&1
```

Expected: compilation error — `containsCJK` not defined.

- [ ] **Step 3: Write minimal implementation**

In `Sources/ContactsPinyinCore/core.swift`:

```swift
import Foundation

/// Check if string contains any CJK Unified Ideograph (U+4E00–U+9FFF).
func containsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) {
            return true
        }
    }
    return false
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter ChineseDetectorTests
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/Sources/ContactsPinyinCore/core.swift contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift
git commit -m "feat: add CJK character detection"
```

---

### Task 3: CompoundSurname — compound surname list and lookup

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (append)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
final class CompoundSurnameTests: XCTestCase {
    func testSplitCompoundSurname_matchesKnownSurnames() {
        let result = splitCompoundSurname("欧阳修")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.surname, "欧阳")
        XCTAssertEqual(result?.given, "修")
    }

    func testSplitCompoundSurname_twoCharSurname() {
        let result = splitCompoundSurname("司马光")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.surname, "司马")
        XCTAssertEqual(result?.given, "光")
    }

    func testSplitCompoundSurname_threeCharSurname() {
        let result = splitCompoundSurname("万俟卨")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.surname, "万俟")
        XCTAssertEqual(result?.given, "卨")
    }

    func testSplitCompoundSurname_singleCharSurname_returnsNil() {
        XCTAssertNil(splitCompoundSurname("王小明"))
        XCTAssertNil(splitCompoundSurname("张"))
    }

    func testSplitCompoundSurname_emptyString_returnsNil() {
        XCTAssertNil(splitCompoundSurname(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter CompoundSurnameTests
```

Expected: compilation error — `splitCompoundSurname` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ContactsPinyinCore/core.swift`:

```swift
// MARK: - Compound Surname

/// Sorted longest-first so "欧阳" matches before "欧".
private let compoundSurnames: [String] = [
    "欧阳", "司马", "上官", "诸葛", "夏侯", "东方", "皇甫", "令狐",
    "慕容", "宇文", "长孙", "公孙", "司徒", "尉迟", "淳于", "太史",
    "申屠", "端木", "万俟", "独孤", "南宫", "拓跋",
].sorted(by: { $0.count > $1.count })

/// If `name` starts with a known compound surname, return (surname, given).
/// Otherwise return nil.
func splitCompoundSurname(_ name: String) -> (surname: String, given: String)? {
    for cs in compoundSurnames {
        if name.hasPrefix(cs), name.count > cs.count {
            let given = String(name.dropFirst(cs.count))
            return (cs, given)
        }
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter CompoundSurnameTests
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: add compound surname detection"
```

---

### Task 4: MultiToneSurname — multi-tone surname lookup table

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (append)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
final class MultiToneSurnameTests: XCTestCase {
    func testLookupMultiToneSurname_knownSurname_returnsCorrectPinyin() {
        XCTAssertEqual(lookupMultiToneSurname("曾"), "Zeng")
        XCTAssertEqual(lookupMultiToneSurname("解"), "Xie")
        XCTAssertEqual(lookupMultiToneSurname("仇"), "Qiu")
        XCTAssertEqual(lookupMultiToneSurname("单"), "Shan")
        XCTAssertEqual(lookupMultiToneSurname("区"), "Ou")
        XCTAssertEqual(lookupMultiToneSurname("查"), "Zha")
        XCTAssertEqual(lookupMultiToneSurname("朴"), "Piao")
        XCTAssertEqual(lookupMultiToneSurname("乐"), "Yue")
    }

    func testLookupMultiToneSurname_compoundSurname() {
        XCTAssertEqual(lookupMultiToneSurname("尉迟"), "Yuchi")
        XCTAssertEqual(lookupMultiToneSurname("长孙"), "Zhangsun")
        XCTAssertEqual(lookupMultiToneSurname("万俟"), "Moqi")
    }

    func testLookupMultiToneSurname_unknownSurname_returnsNil() {
        XCTAssertNil(lookupMultiToneSurname("张"))
        XCTAssertNil(lookupMultiToneSurname("王"))
        XCTAssertNil(lookupMultiToneSurname(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter MultiToneSurnameTests
```

Expected: compilation error — `lookupMultiToneSurname` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ContactsPinyinCore/core.swift`:

```swift
// MARK: - Multi-Tone Surname

/// Maps surnames whose reading differs from CFStringTransform's default.
/// Values are tone-stripped, capitalized pinyin.
private let multiToneSurnames: [String: String] = [
    // Single character
    "曾": "Zeng", "解": "Xie", "仇": "Qiu", "单": "Shan",
    "区": "Ou",  "查": "Zha", "朴": "Piao", "乐": "Yue",
    "盖": "Ge",  "华": "Hua", "任": "Ren", "纪": "Ji",
    "缪": "Miao", "折": "She", "员": "Yun", "燕": "Yan",
    "过": "Guo", "覃": "Qin", "召": "Shao", "种": "Chong",
    "隗": "Wei", "翟": "Zhai", "祭": "Zhai", "阚": "Kan",
    "秘": "Bi",  "都": "Du",  "繁": "Po",  "簿": "Bo",
    "能": "Nai", "句": "Gou", "贲": "Ben", "臧": "Zang",
    // Compound
    "尉迟": "Yuchi", "长孙": "Zhangsun", "万俟": "Moqi",
]

/// Return the known pinyin for a multi-tone surname, or nil.
func lookupMultiToneSurname(_ surname: String) -> String? {
    return multiToneSurnames[surname]
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter MultiToneSurnameTests
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: add multi-tone surname lookup table"
```

---

### Task 5: PinyinConverter — CFStringTransform wrapper

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (append)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
final class PinyinConverterTests: XCTestCase {
    func testToPinyin_simpleChinese() {
        XCTAssertEqual(toPinyin("王"), "wang")
        XCTAssertEqual(toPinyin("小明"), "xiaoming")
    }

    func testToPinyin_withToneMarks_removesThem() {
        // "曾" as surname is Zeng, CFST outputs "zeng" with tone stripped
        let result = toPinyin("曾")
        XCTAssertFalse(result.contains("é"))
        XCTAssertFalse(result.contains("è"))
        XCTAssertFalse(result.contains("ē"))
    }

    func testToPinyin_preservesNonChinese() {
        let result = toPinyin("Tom王")
        XCTAssertTrue(result.contains("Tom"))
        XCTAssertTrue(result.contains("wang"))
    }

    func testToPinyin_emptyString_returnsEmpty() {
        XCTAssertEqual(toPinyin(""), "")
    }

    func testSurnamePinyin_knownMultiTone_usesTable() {
        XCTAssertEqual(surnamePinyin("曾"), "Zeng")
        XCTAssertEqual(surnamePinyin("解"), "Xie")
    }

    func testSurnamePinyin_unknownSurname_usesCFTransform() {
        XCTAssertEqual(surnamePinyin("张"), "Zhang")
        XCTAssertEqual(surnamePinyin("王"), "Wang")
    }

    func testGivenNamePinyin_convertsName() {
        let result = givenNamePinyin("小明")
        XCTAssertEqual(result, "Xiaoming")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter PinyinConverterTests
```

Expected: compilation error — `toPinyin`, `surnamePinyin`, `givenNamePinyin` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ContactsPinyinCore/core.swift`:

```swift
// MARK: - Pinyin Conversion

/// Convert Chinese characters to pinyin without tone marks.
/// Non-CJK characters pass through unchanged.
func toPinyin(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return mutable as String
}

/// Get pinyin for a surname — multi-tone table first, CFST fallback.
func surnamePinyin(_ surname: String) -> String {
    if let known = lookupMultiToneSurname(surname) {
        return known
    }
    return toPinyin(surname).capitalized
}

/// Get pinyin for a given name — always uses CFST.
func givenNamePinyin(_ givenName: String) -> String {
    return toPinyin(givenName).capitalized
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter PinyinConverterTests
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: add pinyin conversion via CFStringTransform"
```

---

### Task 6: NameSplitter — split name into surname + givenName

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (append)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
final class NameSplitterTests: XCTestCase {
    func testSplitName_normalCase() {
        let (surname, given) = splitName(familyName: "王", givenName: "小明")
        XCTAssertEqual(surname, "王")
        XCTAssertEqual(given, "小明")
    }

    func testSplitName_compoundSurname() {
        let (surname, given) = splitName(familyName: "欧阳", givenName: "修")
        XCTAssertEqual(surname, "欧阳")
        XCTAssertEqual(given, "修")
    }

    func testSplitName_noFamilyName_firstCharIsSurname() {
        let (surname, given) = splitName(familyName: "", givenName: "王小明")
        XCTAssertEqual(surname, "王")
        XCTAssertEqual(given, "小明")
    }

    func testSplitName_noFamilyName_singleCharGiven() {
        let (surname, given) = splitName(familyName: "", givenName: "张")
        XCTAssertEqual(surname, "张")
        XCTAssertEqual(given, "")
    }

    func testSplitName_emptyGivenName() {
        let (surname, given) = splitName(familyName: "李", givenName: "")
        XCTAssertEqual(surname, "李")
        XCTAssertEqual(given, "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter NameSplitterTests
```

Expected: compilation error — `splitName` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ContactsPinyinCore/core.swift`:

```swift
// MARK: - Name Splitting

/// Split a Chinese name into (surname, givenName) with compound-surname awareness.
func splitName(familyName: String, givenName: String) -> (surname: String, given: String) {
    let surname: String
    let given: String

    if familyName.isEmpty {
        // No familyName field: infer surname from givenName's first character
        surname = String(givenName.prefix(1))
        given = String(givenName.dropFirst())
    } else if let cs = splitCompoundSurname(familyName) {
        surname = cs.surname
        given = givenName.isEmpty ? cs.given : givenName
    } else {
        surname = familyName
        given = givenName
    }

    return (surname, given)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter NameSplitterTests
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: add name splitting with compound surname support"
```

---

### Task 7: ChangeComputer — compute phonetic changes for contacts

**Files:**
- Modify: `contacts-pinyin/Sources/ContactsPinyinCore/core.swift` (append)
- Modify: `contacts-pinyin/Tests/ContactsPinyinCoreTests/Tests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/ContactsPinyinCoreTests/Tests.swift`:

```swift
final class ChangeComputerTests: XCTestCase {
    func testComputePhoneticChange_needsUpdate() {
        let change = computePhoneticChange(
            familyName: "王", givenName: "小明",
            oldPhoneticFamily: "", oldPhoneticGiven: ""
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.newPhoneticFamily, "Wang")
        XCTAssertEqual(change?.newPhoneticGiven, "Xiaoming")
    }

    func testComputePhoneticChange_compoundSurname() {
        let change = computePhoneticChange(
            familyName: "欧阳", givenName: "修",
            oldPhoneticFamily: "", oldPhoneticGiven: ""
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.newPhoneticFamily, "Ouyang")
        XCTAssertEqual(change?.newPhoneticGiven, "Xiu")
    }

    func testComputePhoneticChange_multiToneSurname() {
        let change = computePhoneticChange(
            familyName: "曾", givenName: "国藩",
            oldPhoneticFamily: "", oldPhoneticGiven: ""
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.newPhoneticFamily, "Zeng")
    }

    func testComputePhoneticChange_alreadyCorrect_returnsNil() {
        let change = computePhoneticChange(
            familyName: "王", givenName: "小明",
            oldPhoneticFamily: "Wang", oldPhoneticGiven: "Xiaoming"
        )
        XCTAssertNil(change)
    }

    func testComputePhoneticChange_noChinese_returnsNil() {
        let change = computePhoneticChange(
            familyName: "Smith", givenName: "John",
            oldPhoneticFamily: "", oldPhoneticGiven: ""
        )
        XCTAssertNil(change)
    }

    func testComputePhoneticChange_emptyFamilyName_infersFromGiven() {
        let change = computePhoneticChange(
            familyName: "", givenName: "张伟",
            oldPhoneticFamily: "", oldPhoneticGiven: ""
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.newPhoneticFamily, "Zhang")
        XCTAssertEqual(change?.newPhoneticGiven, "Wei")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift test --filter ChangeComputerTests
```

Expected: compilation error — `computePhoneticChange` / `PhoneticChange` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ContactsPinyinCore/core.swift`:

```swift
// MARK: - Phonetic Change

struct PhoneticChange {
    let fullName: String          // display name, e.g. "王小明"
    let newPhoneticFamily: String
    let newPhoneticGiven: String
}

/// Compute what the phonetic fields should be for a contact.
/// Returns nil if no Chinese detected or no change needed.
func computePhoneticChange(
    familyName: String,
    givenName: String,
    oldPhoneticFamily: String,
    oldPhoneticGiven: String
) -> PhoneticChange? {
    guard containsCJK(familyName) || containsCJK(givenName) else {
        return nil
    }

    let (surname, given) = splitName(familyName: familyName, givenName: givenName)
    let newFamily = surnamePinyin(surname)
    let newGiven = givenNamePinyin(given)

    guard newFamily != oldPhoneticFamily || newGiven != oldPhoneticGiven else {
        return nil
    }

    let full = familyName.isEmpty ? givenName : "\(familyName)\(givenName)"
    return PhoneticChange(
        fullName: full,
        newPhoneticFamily: newFamily,
        newPhoneticGiven: newGiven
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift test --filter ChangeComputerTests
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/
git commit -m "feat: add phonetic change computation"
```

---

### Task 8: CLI — argument parsing, Contacts integration, dry run, save

**Files:**
- Create: `contacts-pinyin/Sources/cli/main.swift`

- [ ] **Step 1: Write main.swift**

```swift
import Contacts
import ContactsPinyinCore
import Foundation

// MARK: - Argument parsing

let args = CommandLine.arguments.dropFirst()
let dryRun = args.contains("--dry-run")
let groupFilter: String? = {
    if let idx = args.firstIndex(of: "--group"), idx + 1 < args.endIndex {
        return args[args.index(after: idx)]
    }
    return nil
}()

let store = CNContactStore()

// MARK: - Authorization

func requestAccess() -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    store.requestAccess(for: .contacts) { g, _ in
        granted = g
        semaphore.signal()
    }
    semaphore.wait()
    return granted
}

guard requestAccess() else {
    fputs("错误: 需要通讯录访问权限。请前往 系统设置 → 隐私与安全性 → 通讯录 授权。\n", stderr)
    exit(1)
}

// MARK: - Fetch contacts

let keys: [CNKeyDescriptor] = [
    CNContactGivenNameKey as CNKeyDescriptor,
    CNContactFamilyNameKey as CNKeyDescriptor,
    CNContactPhoneticGivenNameKey as CNKeyDescriptor,
    CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
]

let request = CNContactFetchRequest(keysToFetch: keys)

if let groupName = groupFilter {
    let groups = (try? store.groups(matching: nil)) ?? []
    guard let group = groups.first(where: { $0.name == groupName }) else {
        fputs("错误: 未找到群组 '\(groupName)'\n", stderr)
        exit(2)
    }
    request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
}

var changes: [(contact: CNContact, change: PhoneticChange)] = []

do {
    try store.enumerateContacts(with: request) { contact, _ in
        if let change = computePhoneticChange(
            familyName: contact.familyName,
            givenName: contact.givenName,
            oldPhoneticFamily: contact.phoneticFamilyName,
            oldPhoneticGiven: contact.phoneticGivenName
        ) {
            changes.append((contact, change))
        }
    }
} catch {
    fputs("错误: 读取通讯录失败 — \(error.localizedDescription)\n", stderr)
    exit(2)
}

guard !changes.isEmpty else {
    print("没有需要更新的中文联系人。")
    exit(0)
}

// MARK: - Output

let mode = dryRun ? "[预览模式]" : ""
print("\(mode)共找到 \(changes.count) 个中文联系人需要更新：\n")

for (contact, change) in changes {
    let oldFamily = contact.phoneticFamilyName
    let oldGiven = contact.phoneticGivenName
    let oldFamilyDisplay = oldFamily.isEmpty ? "(空)" : oldFamily
    let oldGivenDisplay = oldGiven.isEmpty ? "(空)" : oldGiven

    print("\(change.fullName)")
    if oldFamily != change.newPhoneticFamily {
        print("  姓氏拼音: \(oldFamilyDisplay) → \(change.newPhoneticFamily)")
    }
    if oldGiven != change.newPhoneticGiven {
        print("  名字拼音: \(oldGivenDisplay) → \(change.newPhoneticGiven)")
    }
    print("---")
}

if dryRun {
    print("\n以上 \(changes.count) 个联系人将被更新。使用不带 --dry-run 运行以执行。")
    exit(0)
}

// MARK: - Save

var success = 0
var failed = 0

for (contact, change) in changes {
    guard let mutable = contact.mutableCopy() as? CNMutableContact else {
        failed += 1
        fputs("错误: 无法获取可变副本 — \(change.fullName)\n", stderr)
        continue
    }
    mutable.phoneticFamilyName = change.newPhoneticFamily
    mutable.phoneticGivenName = change.newPhoneticGiven

    let req = CNSaveRequest()
    req.update(mutable)
    do {
        try store.execute(req)
        success += 1
    } catch {
        failed += 1
        fputs("错误: 更新 '\(change.fullName)' 失败 — \(error.localizedDescription)\n", stderr)
    }
}

print("\n成功 \(success) / 失败 \(failed)")
```

- [ ] **Step 2: Build**

```bash
cd contacts-pinyin && swift build
```

Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add contacts-pinyin/Sources/cli/main.swift
git commit -m "feat: add CLI with Contacts integration, dry run, and group filter"
```

---

### Task 9: Test full test suite

- [ ] **Step 1: Run all tests**

```bash
cd contacts-pinyin && swift test
```

Expected: all tests pass (ChineseDetector 4, CompoundSurname 5, MultiToneSurname 3, PinyinConverter 7, NameSplitter 5, ChangeComputer 6 = 30 tests).

- [ ] **Step 2: Commit any fixes if needed**

---

### Task 10: Manual integration test (dry run)

- [ ] **Step 1: Run dry run**

```bash
cd contacts-pinyin && swift run cli -- --dry-run
```

Expected: prompts for Contacts permission, then shows preview of changes (or "没有需要更新的中文联系人" if none).

- [ ] **Step 2: Verify output format matches spec**

Check: old→new display, empty shown as "(空)", summary line at bottom.

---

### Task 11: Install to /usr/local/bin

- [ ] **Step 1: Build release and install**

```bash
cd contacts-pinyin && swift build -c release
cp .build/release/cli /usr/local/bin/contacts-pinyin
chmod +x /usr/local/bin/contacts-pinyin
```

- [ ] **Step 2: Verify installation**

```bash
which contacts-pinyin
contacts-pinyin --dry-run
```

Expected: runs from anywhere.

- [ ] **Step 3: Commit install note**

```bash
git commit --allow-empty -m "docs: note install path /usr/local/bin/contacts-pinyin"
```
