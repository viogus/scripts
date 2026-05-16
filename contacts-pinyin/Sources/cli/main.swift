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

// MARK: - Main

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
            fputs("错误: 无法获取可变副本\n", stderr)
            continue
        }
        var newPhoneNumbers = mutable.phoneNumbers
        var contactChanged = 0
        for i in 0..<newPhoneNumbers.count {
            let oldStr = newPhoneNumbers[i].value.stringValue
            if let normalized = normalizeChinesePhone(oldStr) {
                let newValue = CNPhoneNumber(stringValue: normalized)
                let newLabeled = CNLabeledValue(label: newPhoneNumbers[i].label, value: newValue)
                newPhoneNumbers[i] = newLabeled
                contactChanged += 1
            }
        }
        mutable.phoneNumbers = newPhoneNumbers
        let req = CNSaveRequest()
        req.update(mutable)
        do {
            try store.execute(req)
            success += contactChanged
        } catch {
            failed += contactChanged
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
