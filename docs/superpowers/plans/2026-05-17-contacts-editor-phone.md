# contacts-editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename contacts-pinyin → contacts-editor with subcommand dispatch, add phone number normalization (+86 prefix for Chinese mobiles), and add `list groups` subcommand.

**Architecture:** Rename module ContactsPinyinCore → ContactsEditorCore. Split phone logic into new phone.swift within same module. Rewrite CLI to dispatch subcommands (pinyin/phone/list groups). All subcommands default to dry-run; `--write` to execute.

**Tech Stack:** Swift 5, Contacts.framework, CoreFoundation, SPM

**Files:**
- Rename: `contacts-pinyin/Package.swift`
- Rename dir: `contacts-pinyin/Sources/ContactsPinyinCore/` → `Sources/ContactsEditorCore/`
- Rename dir: `contacts-pinyin/Tests/ContactsPinyinCoreTests/` → `Tests/ContactsEditorCoreTests/`
- Create: `contacts-pinyin/Sources/ContactsEditorCore/phone.swift`
- Create: `contacts-pinyin/Tests/ContactsEditorCoreTests/phone_tests.swift`
- Rename: `contacts-pinyin/Tests/ContactsEditorCoreTests/Tests.swift` → `pinyin_tests.swift`
- Modify: `contacts-pinyin/Sources/ContactsEditorCore/core.swift` (no changes needed beyond module rename)
- Rewrite: `contacts-pinyin/Sources/cli/main.swift`

---

### Task 1: Rename module and directories

**Files:**
- Modify: `contacts-pinyin/Package.swift`
- Rename dir: `contacts-pinyin/Sources/ContactsPinyinCore/` → `contacts-pinyin/Sources/ContactsEditorCore/`
- Rename dir: `contacts-pinyin/Tests/ContactsPinyinCoreTests/` → `contacts-pinyin/Tests/ContactsEditorCoreTests/`

- [ ] **Step 1: Rename directories**

```bash
mv contacts-pinyin/Sources/ContactsPinyinCore contacts-pinyin/Sources/ContactsEditorCore
mv contacts-pinyin/Tests/ContactsPinyinCoreTests contacts-pinyin/Tests/ContactsEditorCoreTests
rm -rf contacts-pinyin/.build
```

- [ ] **Step 2: Update Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "contacts-editor",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "ContactsEditorCore",
            path: "Sources/ContactsEditorCore"
        ),
        .executableTarget(
            name: "cli",
            dependencies: ["ContactsEditorCore"],
            path: "Sources/cli"
        ),
        .executableTarget(
            name: "ContactsEditorCoreTests",
            dependencies: ["ContactsEditorCore"],
            path: "Tests/ContactsEditorCoreTests"
        ),
    ]
)
```

- [ ] **Step 3: Update import in main.swift**

Change line 2 of `Sources/cli/main.swift`:
```swift
import ContactsEditorCore
```

- [ ] **Step 4: Update import in pinyin tests**

Rename and update import: `Tests/ContactsEditorCoreTests/Tests.swift` → `Tests/ContactsEditorCoreTests/pinyin_tests.swift`
```bash
mv contacts-pinyin/Tests/ContactsEditorCoreTests/Tests.swift contacts-pinyin/Tests/ContactsEditorCoreTests/pinyin_tests.swift
```
Change line 1 from `import ContactsPinyinCore` to:
```swift
import ContactsEditorCore
```

- [ ] **Step 5: Build to verify rename**

```bash
cd contacts-pinyin && swift build
```
Expected: builds successfully.

- [ ] **Step 6: Run existing tests**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
Expected: OK 32 tests passed.

- [ ] **Step 7: Commit**

```bash
git add contacts-pinyin/
git commit -m "refactor: rename module ContactsPinyinCore → ContactsEditorCore"
```

---

### Task 2: Create phone.swift with normalizeChinesePhone (TDD)

**Files:**
- Create: `contacts-pinyin/Tests/ContactsEditorCoreTests/phone_tests.swift`
- Create: `contacts-pinyin/Sources/ContactsEditorCore/phone.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ContactsEditorCoreTests/phone_tests.swift`:

```swift
import ContactsEditorCore
import Foundation

// Assertion helpers reused from pinyin_tests.swift pattern
func pexpect<T: Equatable>(_ actual: T, _ expected: T, _ msg: String, file: String = #file, line: Int = #line) {
    if actual != expected {
        fputs("FAIL \(file):\(line) — \(msg): expected \(expected), got \(actual)\n", stderr)
        phoneFailures += 1
    }
}

func pexpectNil<T>(_ actual: T?, _ msg: String, file: String = #file, line: Int = #line) {
    if actual != nil {
        fputs("FAIL \(file):\(line) — \(msg): expected nil, got \(actual!)\n", stderr)
        phoneFailures += 1
    }
}

func pexpectNotNil<T>(_ actual: T?, _ msg: String, file: String = #file, line: Int = #line) {
    if actual == nil {
        fputs("FAIL \(file):\(line) — \(msg): expected non-nil\n", stderr)
        phoneFailures += 1
    }
}

var phoneFailures = 0

// MARK: - Phone Normalization

func test_normalize_bareChinese11Digit() {
    pexpect(normalizeChinesePhone("13800138000"), "+86 13800138000", "bare 11-digit")
}

func test_normalize_11DigitStartsWith1() {
    pexpect(normalizeChinesePhone("15912345678"), "+86 15912345678", "159 prefix")
}

func test_normalize_withSpacesAndDashes() {
    pexpect(normalizeChinesePhone("138-0013-8000"), "+86 13800138000", "dashes stripped")
    pexpect(normalizeChinesePhone("138 0013 8000"), "+86 13800138000", "spaces stripped")
}

func test_normalize_withParentheses() {
    pexpect(normalizeChinesePhone("(138)00138000"), "+86 13800138000", "parens stripped")
}

func test_normalize_alreadyHasPlus86() {
    pexpectNil(normalizeChinesePhone("+86 13800138000"), "already +86 with space")
    pexpectNil(normalizeChinesePhone("+8613800138000"), "already +86 no space")
}

func test_normalize_alreadyHasPlusOther() {
    pexpectNil(normalizeChinesePhone("+1 5551234567"), "already +1")
    pexpectNil(normalizeChinesePhone("+44 7911123456"), "already +44")
}

func test_normalize_not11Digits() {
    pexpectNil(normalizeChinesePhone("1380013800"), "10 digits")
    pexpectNil(normalizeChinesePhone("138001380000"), "12 digits")
    pexpectNil(normalizeChinesePhone("021-12345678"), "landline")
}

func test_normalize_11DigitNotStartingWith1() {
    pexpectNil(normalizeChinesePhone("23800138000"), "starts with 2")
}

func test_normalize_containsNonDigit() {
    pexpectNil(normalizeChinesePhone("1380a138000"), "contains letter")
}

func test_normalize_emptyString() {
    pexpectNil(normalizeChinesePhone(""), "empty")
}

// MARK: - Run

let ptests: [() -> Void] = [
    test_normalize_bareChinese11Digit,
    test_normalize_11DigitStartsWith1,
    test_normalize_withSpacesAndDashes,
    test_normalize_withParentheses,
    test_normalize_alreadyHasPlus86,
    test_normalize_alreadyHasPlusOther,
    test_normalize_not11Digits,
    test_normalize_11DigitNotStartingWith1,
    test_normalize_containsNonDigit,
    test_normalize_emptyString,
]

for t in ptests { t() }

if phoneFailures == 0 {
    print("OK \(ptests.count) phone tests passed")
    exit(0)
} else {
    fputs("FAIL \(phoneFailures) assertion(s) across \(ptests.count) phone tests\n", stderr)
    exit(1)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
The phone_tests.swift file won't be included yet because the test target only runs its own files. We need to combine test runners later. For now, run the phone test standalone:
```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests 2>&1
```
Expected: phone tests don't run yet (only pinyin_tests.swift is in the target). Build succeeds though.

Actually, the test target compiles all .swift files in its directory. But we have a problem: both pinyin_tests.swift and phone_tests.swift have top-level code (the test runner loop + exit). We can't have two files with top-level code in the same target.

**Solution:** merge the test runners. Extract assertion helpers to a shared file, and have one test runner that calls both sets of tests.

- [ ] **Step 3: Extract shared assertion helpers**

Create `Tests/ContactsEditorCoreTests/helpers.swift`:

```swift
var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ msg: String, file: String = #file, line: Int = #line) {
    if actual != expected {
        fputs("FAIL \(file):\(line) — \(msg): expected \(expected), got \(actual)\n", stderr)
        failures += 1
    }
}

func expectTrue(_ actual: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !actual {
        fputs("FAIL \(file):\(line) — \(msg): expected true, got false\n", stderr)
        failures += 1
    }
}

func expectFalse(_ actual: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if actual {
        fputs("FAIL \(file):\(line) — \(msg): expected false, got true\n", stderr)
        failures += 1
    }
}

func expectNotNil<T>(_ actual: T?, _ msg: String, file: String = #file, line: Int = #line) {
    if actual == nil {
        fputs("FAIL \(file):\(line) — \(msg): expected non-nil\n", stderr)
        failures += 1
    }
}

func expectNil<T>(_ actual: T?, _ msg: String, file: String = #file, line: Int = #line) {
    if actual != nil {
        fputs("FAIL \(file):\(line) — \(msg): expected nil, got \(actual!)\n", stderr)
        failures += 1
    }
}
```

- [ ] **Step 4: Strip helpers and runner from pinyin_tests.swift**

Remove lines 1-39 (import + helpers + `var failures = 0`) from pinyin_tests.swift, and remove lines 243-289 (test registry + run loop). Keep only the test functions within their MARK sections.

- [ ] **Step 5: Update phone_tests.swift to use shared helpers**

Remove the duplicate helpers (`pexpect`, `pexpectNil`, `pexpectNotNil`, `var phoneFailures = 0`), replace calls:
- `pexpect(` → `expect(`
- `pexpectNil(` → `expectNil(`
- `pexpectNotNil(` → `expectNotNil(`
- Remove `phoneFailures` variable (no longer needed, shared `failures` used instead)
- Remove the run loop at the bottom

- [ ] **Step 6: Create unified test runner**

Create `Tests/ContactsEditorCoreTests/main.swift`:

```swift
import ContactsEditorCore
import Foundation

let allTests: [(String, () -> Void)] = []

func register(_ name: String, _ fn: @escaping () -> Void) {
    // Swift doesn't support mutable global arrays well with top-level code.
    // Instead, we just call all tests directly here.
}

// Invoke all test functions from both files.
// pinyin_tests.swift functions:
runPinyinTests()
// phone_tests.swift functions:
runPhoneTests()

if failures == 0 {
    print("OK all tests passed")
    exit(0)
} else {
    fputs("FAIL \(failures) assertion(s)\n", stderr)
    exit(1)
}
```

Hmm, this approach with shared globals and cross-file function calls gets complex with top-level code.

**Better approach:** Keep both test files as separate executable targets, or merge everything into a single file.

**Simplest approach:** Append phone tests to the existing pinyin_tests.swift as a single file. This avoids the multi-file top-level code problem entirely.

Let me revise.

- [ ] **Step 1 (revised): Append phone tests to pinyin_tests.swift**

Add phone test functions to `Tests/ContactsEditorCoreTests/pinyin_tests.swift` after the existing test functions but before the test registry array. Then add phone tests to the registry.

Add after line 239 (after `test_change_noFamily_infers`), before the `// MARK: - Run all tests` section:

```swift
// MARK: - Phone Normalization

func test_normalize_bareChinese11Digit() {
    expect(normalizeChinesePhone("13800138000"), "+86 13800138000", "bare 11-digit")
}

func test_normalize_11DigitStartsWith1() {
    expect(normalizeChinesePhone("15912345678"), "+86 15912345678", "159 prefix")
}

func test_normalize_withSpacesAndDashes() {
    expect(normalizeChinesePhone("138-0013-8000"), "+86 13800138000", "dashes stripped")
    expect(normalizeChinesePhone("138 0013 8000"), "+86 13800138000", "spaces stripped")
}

func test_normalize_withParentheses() {
    expect(normalizeChinesePhone("(138)00138000"), "+86 13800138000", "parens stripped")
}

func test_normalize_alreadyHasPlus86() {
    expectNil(normalizeChinesePhone("+86 13800138000"), "already +86 with space")
    expectNil(normalizeChinesePhone("+8613800138000"), "already +86 no space")
}

func test_normalize_alreadyHasPlusOther() {
    expectNil(normalizeChinesePhone("+1 5551234567"), "already +1")
    expectNil(normalizeChinesePhone("+44 7911123456"), "already +44")
}

func test_normalize_not11Digits() {
    expectNil(normalizeChinesePhone("1380013800"), "10 digits")
    expectNil(normalizeChinesePhone("138001380000"), "12 digits")
    expectNil(normalizeChinesePhone("021-12345678"), "landline")
}

func test_normalize_11DigitNotStartingWith1() {
    expectNil(normalizeChinesePhone("23800138000"), "starts with 2")
}

func test_normalize_containsNonDigit() {
    expectNil(normalizeChinesePhone("1380a138000"), "contains letter")
}

func test_normalize_emptyString() {
    expectNil(normalizeChinesePhone(""), "empty")
}
```

Add to the test registry array (before the closing `]`):

```swift
    ("phone_bare11Digit", test_normalize_bareChinese11Digit),
    ("phone_11DigitStartsWith1", test_normalize_11DigitStartsWith1),
    ("phone_withSpacesAndDashes", test_normalize_withSpacesAndDashes),
    ("phone_withParentheses", test_normalize_withParentheses),
    ("phone_alreadyHasPlus86", test_normalize_alreadyHasPlus86),
    ("phone_alreadyHasPlusOther", test_normalize_alreadyHasPlusOther),
    ("phone_not11Digits", test_normalize_not11Digits),
    ("phone_11DigitNotStartingWith1", test_normalize_11DigitNotStartingWith1),
    ("phone_containsNonDigit", test_normalize_containsNonDigit),
    ("phone_empty", test_normalize_emptyString),
```

Update the test count comment from `// MARK: - Task 7: Change Computer` to reflect the expanded scope.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
Expected: compilation error — `normalizeChinesePhone` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ContactsEditorCore/phone.swift`:

```swift
import Foundation

// MARK: - Phone Normalization

/// Normalize a Chinese mobile phone number by prepending +86.
/// Returns the new number string, or nil if no change needed.
public func normalizeChinesePhone(_ number: String) -> String? {
    let stripped = number.replacingOccurrences(
        of: #"[\s\-\(\)]"#,
        with: "",
        options: .regularExpression
    )
    guard !stripped.hasPrefix("+") else { return nil }
    guard stripped.count == 11, stripped.hasPrefix("1") else { return nil }
    guard stripped.allSatisfy({ $0.isNumber }) else { return nil }
    return "+86 \(stripped)"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
Expected: OK 42 tests passed (32 pinyin + 10 phone).

- [ ] **Step 5: Commit**

```bash
git add contacts-pinyin/Sources/ContactsEditorCore/phone.swift contacts-pinyin/Tests/ContactsEditorCoreTests/
git commit -m "feat: add phone number normalization for Chinese mobiles (+86)"
```

---

### Task 3: Rewrite CLI with subcommand dispatch

**Files:**
- Modify: `contacts-pinyin/Sources/cli/main.swift`

- [ ] **Step 1: Write the new main.swift**

```swift
import Contacts
import ContactsEditorCore
import Foundation

// MARK: - Help

func printHelp() {
    print("""
    contacts-editor — macOS Contacts 编辑工具

    用法:
      contacts-editor pinyin                  拼音 dry-run
      contacts-editor pinyin --write           拼音执行
      contacts-editor pinyin --group <name>    拼音分组过滤
      contacts-editor phone                    电话 dry-run
      contacts-editor phone --write            电话执行
      contacts-editor phone --group <name>     电话分组过滤
      contacts-editor list groups              列出所有群组

    """)
}

// MARK: - Argument parsing

let args = CommandLine.arguments.dropFirst()

guard let subcommand = args.first else {
    printHelp()
    exit(0)
}

let subArgs = args.dropFirst()
let write = subArgs.contains("--write")
let groupFilter: String? = {
    if let idx = subArgs.firstIndex(of: "--group"), idx + 1 < subArgs.endIndex {
        return subArgs[subArgs.index(after: idx)]
    }
    return nil
}()

// MARK: - Contacts access

MainActor.assumeIsolated {
    let store = CNContactStore()

    let semaphore = DispatchSemaphore(value: 0)
    class Box { var value = false }
    let granted = Box()
    store.requestAccess(for: .contacts) { g, _ in
        granted.value = g
        semaphore.signal()
    }
    semaphore.wait()

    guard granted.value else {
        fputs("错误: 需要通讯录访问权限。请前往 系统设置 → 隐私与安全性 → 通讯录 授权。\n", stderr)
        exit(1)
    }

    switch subcommand {
    case "pinyin":
        runPinyin(store: store, write: write, groupFilter: groupFilter)
    case "phone":
        runPhone(store: store, write: write, groupFilter: groupFilter)
    case "list":
        if subArgs.first == "groups" {
            runListGroups(store: store)
        } else {
            fputs("错误: 未知子命令 'list \(subArgs.first ?? "")'\n", stderr)
            exit(2)
        }
    default:
        fputs("错误: 未知子命令 '\(subcommand)'\n", stderr)
        printHelp()
        exit(2)
    }
}

// MARK: - Subcommand: pinyin

func runPinyin(store: CNContactStore, write: Bool, groupFilter: String?) {
    let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneticGivenNameKey as CNKeyDescriptor,
        CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
    ]

    let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
    if let name = groupFilter {
        guard let group = findGroup(name, store: store) else {
            fputs("错误: 未找到群组 '\(name)'\n", stderr)
            exit(2)
        }
        fetchRequest.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
    }

    var changes: [(contact: CNContact, change: PhoneticChange)] = []
    do {
        try store.enumerateContacts(with: fetchRequest) { contact, _ in
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

    let mode = write ? "" : "[预览模式] "
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

    if !write {
        print("\n以上 \(changes.count) 个联系人将被更新。使用 --write 执行。")
        exit(0)
    }

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
}

// MARK: - Subcommand: phone

func runPhone(store: CNContactStore, write: Bool, groupFilter: String?) {
    let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
    if let name = groupFilter {
        guard let group = findGroup(name, store: store) else {
            fputs("错误: 未找到群组 '\(name)'\n", stderr)
            exit(2)
        }
        fetchRequest.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
    }

    struct PhoneChange {
        let contact: CNContact
        let oldNumbers: [String]
        let newNumbers: [String]
    }

    var changes: [PhoneChange] = []
    do {
        try store.enumerateContacts(with: fetchRequest) { contact, _ in
            var oldNums: [String] = []
            var newNums: [String] = []
            for labeled in contact.phoneNumbers {
                let oldStr = labeled.value.stringValue
                if let normalized = normalizeChinesePhone(oldStr) {
                    oldNums.append(oldStr)
                    newNums.append(normalized)
                }
            }
            if !oldNums.isEmpty {
                changes.append(PhoneChange(contact: contact, oldNumbers: oldNums, newNumbers: newNums))
            }
        }
    } catch {
        fputs("错误: 读取通讯录失败 — \(error.localizedDescription)\n", stderr)
        exit(2)
    }

    guard !changes.isEmpty else {
        print("没有需要更新的电话号码。")
        exit(0)
    }

    let mode = write ? "" : "[预览模式] "
    let totalChanges = changes.reduce(0) { $0 + $1.oldNumbers.count }
    print("\(mode)共找到 \(totalChanges) 个电话号码需要更新：\n")

    for pc in changes {
        let name = "\(pc.contact.familyName)\(pc.contact.givenName)"
        print(name)
        for i in 0..<pc.oldNumbers.count {
            print("  \(pc.oldNumbers[i]) → \(pc.newNumbers[i])")
        }
        print("---")
    }

    if !write {
        print("\n以上 \(totalChanges) 个电话号码将被更新。使用 --write 执行。")
        exit(0)
    }

    var success = 0
    var failed = 0
    for pc in changes {
        guard let mutable = pc.contact.mutableCopy() as? CNMutableContact else {
            failed += pc.oldNumbers.count
            fputs("错误: 无法获取可变副本 — \(pc.contact.familyName)\(pc.contact.givenName)\n", stderr)
            continue
        }
        var newPhoneNumbers = mutable.phoneNumbers
        for i in 0..<newPhoneNumbers.count {
            let oldStr = newPhoneNumbers[i].value.stringValue
            if let normalized = normalizeChinesePhone(oldStr) {
                let newValue = CNPhoneNumber(stringValue: normalized)
                let newLabeled = CNLabeledValue(label: newPhoneNumbers[i].label, value: newValue)
                newPhoneNumbers[i] = newLabeled
                success += 1
            }
        }
        mutable.phoneNumbers = newPhoneNumbers
        let req = CNSaveRequest()
        req.update(mutable)
        do {
            try store.execute(req)
        } catch {
            failed += success
            success = 0
            fputs("错误: 更新电话号码失败 — \(error.localizedDescription)\n", stderr)
        }
    }
    print("\n成功 \(success) / 失败 \(failed)")
}

// MARK: - Subcommand: list groups

func runListGroups(store: CNContactStore) {
    let groups = (try? store.groups(matching: nil)) ?? []
    if groups.isEmpty {
        print("(无群组)")
    } else {
        for g in groups {
            print(g.name)
        }
    }
}

// MARK: - Helpers

func findGroup(_ name: String, store: CNContactStore) -> CNGroup? {
    let groups = (try? store.groups(matching: nil)) ?? []
    return groups.first(where: { $0.name == name })
}
```

- [ ] **Step 2: Build**

```bash
cd contacts-pinyin && swift build
```
Expected: builds successfully.

- [ ] **Step 3: Run tests**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
Expected: OK 42 tests passed.

- [ ] **Step 4: Dry-run pinyin to verify no regression**

```bash
cd contacts-pinyin && swift run cli -- pinyin 2>&1 | head -10
```
Expected: shows pinyin preview.

- [ ] **Step 5: Dry-run phone**

```bash
cd contacts-pinyin && swift run cli -- phone 2>&1 | head -10
```
Expected: shows phone changes or "没有需要更新的电话号码。"

- [ ] **Step 6: List groups**

```bash
cd contacts-pinyin && swift run cli -- list groups
```
Expected: lists group names.

- [ ] **Step 7: Commit**

```bash
git add contacts-pinyin/Sources/cli/main.swift
git commit -m "feat: add subcommand dispatch, phone normalization CLI, list groups"
```

---

### Task 4: Install and verify

- [ ] **Step 1: Build release and install**

```bash
cd contacts-pinyin && swift build -c release
sudo cp .build/release/cli /usr/local/bin/contacts-editor
```

- [ ] **Step 2: Verify installation**

```bash
which contacts-editor
contacts-editor
contacts-editor list groups
contacts-editor pinyin 2>&1 | tail -3
contacts-editor phone 2>&1 | tail -3
```
Expected: help shown, groups listed, pinyin preview works, phone preview works.

- [ ] **Step 3: Commit install note**

```bash
git commit --allow-empty -m "docs: note install path /usr/local/bin/contacts-editor"
```

---

### Task 5: Final verification

- [ ] **Step 1: Run full test suite**

```bash
cd contacts-pinyin && swift run ContactsEditorCoreTests
```
Expected: OK 42 tests passed.

- [ ] **Step 2: Build clean**

```bash
cd contacts-pinyin && rm -rf .build && swift build
```
Expected: exit 0, no errors.

- [ ] **Step 3: Run all subcommands dry**

```bash
contacts-editor pinyin 2>&1 | tail -3
contacts-editor phone 2>&1 | tail -3
contacts-editor list groups
```
