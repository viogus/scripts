import Testing
@testable import ContactsPinyinCore

@Test(arguments: ["王小明", "张"])
func testContainsCJK_withChinese(text: String) {
    #expect(containsCJK(text))
}

@Test(arguments: ["Tom 王", "Hello世界"])
func testContainsCJK_withMixedText(text: String) {
    #expect(containsCJK(text))
}

@Test(arguments: ["Tom", "", "abc123"])
func testContainsCJK_withoutChinese(text: String) {
    #expect(!containsCJK(text))
}

@Test func testContainsCJK_withJapanese() {
    #expect(containsCJK("東京"))
}
