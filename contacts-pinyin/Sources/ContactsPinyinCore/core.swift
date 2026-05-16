import Foundation

// MARK: - CJK Detection

/// Check if string contains any CJK Unified Ideograph (U+4E00–U+9FFF).
public func containsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) {
            return true
        }
    }
    return false
}

// MARK: - Compound Surname

/// Sorted longest-first so "欧阳" matches before "欧".
private let compoundSurnames: [String] = [
    "欧阳", "司马", "上官", "诸葛", "夏侯", "东方", "皇甫", "令狐",
    "慕容", "宇文", "长孙", "公孙", "司徒", "尉迟", "淳于", "太史",
    "申屠", "端木", "万俟", "独孤", "南宫", "拓跋",
].sorted(by: { $0.count > $1.count })

/// If `name` starts with a known compound surname, return (surname, given).
/// Otherwise return nil.
public func splitCompoundSurname(_ name: String) -> (surname: String, given: String)? {
    for cs in compoundSurnames {
        if name.hasPrefix(cs), name.count > cs.count {
            let given = String(name.dropFirst(cs.count))
            return (cs, given)
        }
    }
    return nil
}

// MARK: - Multi-Tone Surname

/// Maps surnames whose reading differs from CFStringTransform's default.
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
public func lookupMultiToneSurname(_ surname: String) -> String? {
    return multiToneSurnames[surname]
}

// MARK: - Pinyin Conversion

public func toPinyin(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    // CFST inserts spaces between syllables; join only pinyin syllables.
    let joined = (mutable as String).replacingOccurrences(
        of: #"(?<=[a-z]) (?=[a-z])"#,
        with: "",
        options: .regularExpression
    )
    return joined
}

public func surnamePinyin(_ surname: String) -> String {
    if let known = lookupMultiToneSurname(surname) {
        return known
    }
    return toPinyin(surname).capitalized
}

public func givenNamePinyin(_ givenName: String) -> String {
    return toPinyin(givenName).capitalized
}

// MARK: - Name Splitting

public func splitName(familyName: String, givenName: String) -> (surname: String, given: String) {
    let surname: String
    let given: String

    if familyName.isEmpty {
        // No familyName field: infer surname from givenName's first character
        surname = String(givenName.prefix(1))
        given = String(givenName.dropFirst())
    } else if let cs = splitCompoundSurname(familyName) {
        surname = cs.surname
        given = givenName.isEmpty ? cs.given : givenName
    } else if givenName.isEmpty && familyName.count > 1 {
        // Full name stored in familyName field; infer the split
        if let cs = splitCompoundSurname(familyName) {
            surname = cs.surname
            given = cs.given
        } else {
            surname = String(familyName.prefix(1))
            given = String(familyName.dropFirst())
        }
    } else {
        surname = familyName
        given = givenName
    }

    return (surname, given)
}

// MARK: - Phonetic Change

public struct PhoneticChange {
    public let fullName: String
    public let newPhoneticFamily: String
    public let newPhoneticGiven: String
}

/// Compute what the phonetic fields should be for a contact.
/// Returns nil if no Chinese detected or no change needed.
public func computePhoneticChange(
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
