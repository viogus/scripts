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

// MARK: - Main

// CLI top-level runs on the main thread; assume MainActor for Contacts.
MainActor.assumeIsolated {
    let store = CNContactStore()

    // Authorization
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    store.requestAccess(for: .contacts) { g, _ in
        granted = g
        semaphore.signal()
    }
    semaphore.wait()

    guard granted else {
        fputs("错误: 需要通讯录访问权限。请前往 系统设置 → 隐私与安全性 → 通讯录 授权。\n", stderr)
        exit(1)
    }

    // Fetch contacts
    let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneticGivenNameKey as CNKeyDescriptor,
        CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
    ]

    let fetchRequest = CNContactFetchRequest(keysToFetch: keys)

    if let groupName = groupFilter {
        let groups = (try? store.groups(matching: nil)) ?? []
        guard let group = groups.first(where: { $0.name == groupName }) else {
            fputs("错误: 未找到群组 '\(groupName)'\n", stderr)
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

    // Output
    let mode = dryRun ? "[预览模式] " : ""
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

    // Save
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
