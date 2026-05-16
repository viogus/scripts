import ContactsEditorCore
import Foundation

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

// MARK: - Task 2: CJK Detection

func test_cjk_withChinese() {
    expectTrue(containsCJK("王小明"), "containsCJK 王小明")
    expectTrue(containsCJK("张"), "containsCJK 张")
}

func test_cjk_withMixed() {
    expectTrue(containsCJK("Tom 王"), "containsCJK Tom 王")
    expectTrue(containsCJK("Hello世界"), "containsCJK Hello世界")
}

func test_cjk_withoutChinese() {
    expectFalse(containsCJK("Tom"), "containsCJK Tom")
    expectFalse(containsCJK(""), "containsCJK empty")
    expectFalse(containsCJK("abc123"), "containsCJK abc123")
}

func test_cjk_japanese() {
    expectTrue(containsCJK("東京"), "containsCJK 東京")
}

func test_cjk_extensionA() {
    // U+34D7 㓗 (Extension A character sometimes used in names)
    expectTrue(containsCJK("㓗"), "containsCJK Extension A")
}

// MARK: - Task 3: Compound Surname

func test_compound_matches() {
    let r = splitCompoundSurname("欧阳修")
    expectNotNil(r, "splitCompoundSurname 欧阳修")
    expect(r?.surname, "欧阳", "surname 欧阳")
    expect(r?.given, "修", "given 修")
}

func test_compound_twoChar() {
    let r = splitCompoundSurname("司马光")
    expectNotNil(r, "splitCompoundSurname 司马光")
    expect(r?.surname, "司马", "surname 司马")
    expect(r?.given, "光", "given 光")
}

func test_compound_singleChar_returnsNil() {
    expectNil(splitCompoundSurname("王小明"), "splitCompoundSurname 王小明")
    expectNil(splitCompoundSurname("张"), "splitCompoundSurname 张")
}

func test_compound_empty_returnsNil() {
    expectNil(splitCompoundSurname(""), "splitCompoundSurname empty")
}

// MARK: - Task 4: Multi-Tone Surname

func test_multitone_known() {
    expect(lookupMultiToneSurname("曾"), "Zeng", "lookup 曾")
    expect(lookupMultiToneSurname("解"), "Xie", "lookup 解")
    expect(lookupMultiToneSurname("仇"), "Qiu", "lookup 仇")
    expect(lookupMultiToneSurname("单"), "Shan", "lookup 单")
    expect(lookupMultiToneSurname("区"), "Ou", "lookup 区")
    expect(lookupMultiToneSurname("查"), "Zha", "lookup 查")
    expect(lookupMultiToneSurname("朴"), "Piao", "lookup 朴")
    expect(lookupMultiToneSurname("乐"), "Yue", "lookup 乐")
}

func test_multitone_compound() {
    expect(lookupMultiToneSurname("尉迟"), "Yuchi", "lookup 尉迟")
    expect(lookupMultiToneSurname("长孙"), "Zhangsun", "lookup 长孙")
    expect(lookupMultiToneSurname("万俟"), "Moqi", "lookup 万俟")
}

func test_multitone_unknown() {
    expectNil(lookupMultiToneSurname("张"), "lookup 张")
    expectNil(lookupMultiToneSurname("王"), "lookup 王")
    expectNil(lookupMultiToneSurname(""), "lookup empty")
}

// MARK: - Task 5: Pinyin Converter

func test_pinyin_simple() {
    expect(toPinyin("王"), "wang", "toPinyin 王")
    expect(toPinyin("小明"), "xiaoming", "toPinyin 小明")
}

func test_pinyin_removesTones() {
    let r = toPinyin("曾")
    expectFalse(r.contains("é"), "no é")
    expectFalse(r.contains("è"), "no è")
    expectFalse(r.contains("ē"), "no ē")
}

func test_pinyin_preservesNonChinese() {
    let r = toPinyin("Tom王")
    expectTrue(r.contains("Tom"), "contains Tom")
    expectTrue(r.contains("wang"), "contains wang")
}

func test_pinyin_empty() {
    expect(toPinyin(""), "", "toPinyin empty")
}

func test_surnamePinyin_known() {
    expect(surnamePinyin("曾"), "Zeng", "surnamePinyin 曾")
    expect(surnamePinyin("解"), "Xie", "surnamePinyin 解")
}

func test_surnamePinyin_unknown() {
    expect(surnamePinyin("张"), "Zhang", "surnamePinyin 张")
    expect(surnamePinyin("王"), "Wang", "surnamePinyin 王")
}

func test_givenNamePinyin() {
    expect(givenNamePinyin("小明"), "Xiaoming", "givenNamePinyin 小明")
}

// MARK: - Task 6: Name Splitter

func test_splitName_normal() {
    let (s, g) = splitName(familyName: "王", givenName: "小明")
    expect(s, "王", "surname")
    expect(g, "小明", "given")
}

func test_splitName_compound() {
    let (s, g) = splitName(familyName: "欧阳", givenName: "修")
    expect(s, "欧阳", "surname")
    expect(g, "修", "given")
}

func test_splitName_noFamily() {
    let (s, g) = splitName(familyName: "", givenName: "王小明")
    expect(s, "王", "surname inferred")
    expect(g, "小明", "given after inference")
}

func test_splitName_noFamily_single() {
    let (s, g) = splitName(familyName: "", givenName: "张")
    expect(s, "张", "surname single")
    expect(g, "", "given empty")
}

func test_splitName_emptyGiven() {
    let (s, g) = splitName(familyName: "李", givenName: "")
    expect(s, "李", "surname")
    expect(g, "", "given")
}

func test_splitName_fullNameInFamily() {
    // Full name "王明海" stored in familyName, givenName empty
    let (s, g) = splitName(familyName: "王明海", givenName: "")
    expect(s, "王", "surname inferred")
    expect(g, "明海", "given inferred")
}

func test_splitName_fullNameInFamily_compound() {
    // Full compound-surname name in familyName
    let (s, g) = splitName(familyName: "欧阳修", givenName: "")
    expect(s, "欧阳", "compound surname")
    expect(g, "修", "given")
}

// MARK: - Task 7: Change Computer

func test_change_needsUpdate() {
    let c = computePhoneticChange(familyName: "王", givenName: "小明", oldPhoneticFamily: "", oldPhoneticGiven: "")
    expectNotNil(c, "change not nil")
    expect(c?.newPhoneticFamily, "Wang", "newPhoneticFamily")
    expect(c?.newPhoneticGiven, "Xiaoming", "newPhoneticGiven")
}

func test_change_compound() {
    let c = computePhoneticChange(familyName: "欧阳", givenName: "修", oldPhoneticFamily: "", oldPhoneticGiven: "")
    expectNotNil(c, "change not nil")
    expect(c?.newPhoneticFamily, "Ouyang", "newPhoneticFamily")
    expect(c?.newPhoneticGiven, "Xiu", "newPhoneticGiven")
}

func test_change_multiTone() {
    let c = computePhoneticChange(familyName: "曾", givenName: "国藩", oldPhoneticFamily: "", oldPhoneticGiven: "")
    expectNotNil(c, "change not nil")
    expect(c?.newPhoneticFamily, "Zeng", "newPhoneticFamily")
}

func test_change_alreadyCorrect() {
    let c = computePhoneticChange(familyName: "王", givenName: "小明", oldPhoneticFamily: "Wang", oldPhoneticGiven: "Xiaoming")
    expectNil(c, "already correct")
}

func test_change_noChinese() {
    let c = computePhoneticChange(familyName: "Smith", givenName: "John", oldPhoneticFamily: "", oldPhoneticGiven: "")
    expectNil(c, "no Chinese")
}

func test_change_noFamily_infers() {
    let c = computePhoneticChange(familyName: "", givenName: "张伟", oldPhoneticFamily: "", oldPhoneticGiven: "")
    expectNotNil(c, "change not nil")
    expect(c?.newPhoneticFamily, "Zhang", "newPhoneticFamily")
    expect(c?.newPhoneticGiven, "Wei", "newPhoneticGiven")
}

// MARK: - Run all tests

let tests: [(String, () -> Void)] = [
    ("cjk_withChinese", test_cjk_withChinese),
    ("cjk_withMixed", test_cjk_withMixed),
    ("cjk_withoutChinese", test_cjk_withoutChinese),
    ("cjk_japanese", test_cjk_japanese),
    ("cjk_extensionA", test_cjk_extensionA),
    ("compound_matches", test_compound_matches),
    ("compound_twoChar", test_compound_twoChar),
    ("compound_singleChar", test_compound_singleChar_returnsNil),
    ("compound_empty", test_compound_empty_returnsNil),
    ("multitone_known", test_multitone_known),
    ("multitone_compound", test_multitone_compound),
    ("multitone_unknown", test_multitone_unknown),
    ("pinyin_simple", test_pinyin_simple),
    ("pinyin_removesTones", test_pinyin_removesTones),
    ("pinyin_preservesNonChinese", test_pinyin_preservesNonChinese),
    ("pinyin_empty", test_pinyin_empty),
    ("surnamePinyin_known", test_surnamePinyin_known),
    ("surnamePinyin_unknown", test_surnamePinyin_unknown),
    ("givenNamePinyin", test_givenNamePinyin),
    ("splitName_normal", test_splitName_normal),
    ("splitName_compound", test_splitName_compound),
    ("splitName_noFamily", test_splitName_noFamily),
    ("splitName_noFamily_single", test_splitName_noFamily_single),
    ("splitName_emptyGiven", test_splitName_emptyGiven),
    ("splitName_fullNameInFamily", test_splitName_fullNameInFamily),
    ("splitName_fullNameInFamily_compound", test_splitName_fullNameInFamily_compound),
    ("change_needsUpdate", test_change_needsUpdate),
    ("change_compound", test_change_compound),
    ("change_multiTone", test_change_multiTone),
    ("change_alreadyCorrect", test_change_alreadyCorrect),
    ("change_noChinese", test_change_noChinese),
    ("change_noFamily", test_change_noFamily_infers),
]

for (_, testFn) in tests {
    testFn()
}

if failures == 0 {
    print("OK \(tests.count) tests passed")
    exit(0)
} else {
    fputs("FAIL \(failures) assertion(s) across \(tests.count) tests\n", stderr)
    exit(1)
}
