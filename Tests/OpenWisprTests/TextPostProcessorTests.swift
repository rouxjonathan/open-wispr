import XCTest
@testable import OpenWisprLib

final class TextPostProcessorTests: XCTestCase {

    func testPeriodReplacement() {
        XCTAssertEqual(TextPostProcessor.process("hello period"), "hello.")
    }

    func testCommaReplacement() {
        XCTAssertEqual(TextPostProcessor.process("one comma two"), "one, two")
    }

    func testQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("how are you question mark"), "how are you?")
    }

    func testExclamationMark() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation mark"), "wow!")
    }

    func testExclamationPoint() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation point"), "wow!")
    }

    func testColon() {
        XCTAssertEqual(TextPostProcessor.process("note colon"), "note:")
    }

    func testSemicolon() {
        XCTAssertEqual(TextPostProcessor.process("first semicolon second"), "first; second")
    }

    func testEllipsis() {
        XCTAssertEqual(TextPostProcessor.process("wait ellipsis"), "wait...")
    }

    func testNewLine() {
        XCTAssertEqual(TextPostProcessor.process("hello new line world"), "hello \n world")
    }

    func testNewParagraph() {
        XCTAssertEqual(TextPostProcessor.process("hello new paragraph world"), "hello \n\n world")
    }

    func testOpenCloseQuotes() {
        XCTAssertEqual(TextPostProcessor.process("he said open quote hello close quote"), "he said \" hello \"")
    }

    func testOpenCloseParens() {
        XCTAssertEqual(TextPostProcessor.process("open paren note close paren"), "( note )")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(TextPostProcessor.process("hello Period"), "hello.")
    }

    func testMultiplePunctuationInOneSentence() {
        XCTAssertEqual(TextPostProcessor.process("hello comma how are you question mark"), "hello, how are you?")
    }

    func testSpacingFixRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello , world"), "hello, world")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(TextPostProcessor.process("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(TextPostProcessor.process(""), "")
    }

    func testFullStop() {
        XCTAssertEqual(TextPostProcessor.process("done full stop"), "done.")
    }

    func testDash() {
        XCTAssertEqual(TextPostProcessor.process("one dash two"), "one  — two")
    }

    func testHyphen() {
        XCTAssertEqual(TextPostProcessor.process("well hyphen known"), "well - known")
    }

    func testSemiColonTwoWords() {
        XCTAssertEqual(TextPostProcessor.process("first semi colon second"), "first semi: second")
    }

    func testNewlineSingleWord() {
        XCTAssertEqual(TextPostProcessor.process("hello newline world"), "hello \n world")
    }

    func testEnsureSpaceAfterPunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello,world"), "hello, world")
    }

    // MARK: - User replacements

    func testApplyReplacementsBasic() {
        let result = TextPostProcessor.applyReplacements(
            "I use cloud code daily",
            replacements: [("cloud code", "Claude code")]
        )
        XCTAssertEqual(result, "I use Claude code daily")
    }

    func testApplyReplacementsCaseInsensitive() {
        let result = TextPostProcessor.applyReplacements(
            "Cloud Code rocks",
            replacements: [("cloud code", "Claude code")]
        )
        XCTAssertEqual(result, "Claude code rocks")
    }

    func testApplyReplacementsRespectsWordBoundary() {
        let result = TextPostProcessor.applyReplacements(
            "icloud is fine but cloud is not",
            replacements: [("cloud", "Claude")]
        )
        XCTAssertEqual(result, "icloud is fine but Claude is not")
    }

    func testApplyReplacementsOrderPreserved() {
        let result = TextPostProcessor.applyReplacements(
            "a b",
            replacements: [("a", "b"), ("b", "c")]
        )
        XCTAssertEqual(result, "c c")
    }

    func testApplyReplacementsEmptyListPassthrough() {
        XCTAssertEqual(
            TextPostProcessor.applyReplacements("hello world", replacements: []),
            "hello world"
        )
    }

    func testApplyReplacementsEscapesRegexMetachars() {
        let result = TextPostProcessor.applyReplacements(
            "see node.js docs",
            replacements: [("node.js", "Node.js")]
        )
        XCTAssertEqual(result, "see Node.js docs")
    }

    func testApplyReplacementsLiteralDollarInTarget() {
        let result = TextPostProcessor.applyReplacements(
            "price tag",
            replacements: [("price", "$10")]
        )
        XCTAssertEqual(result, "$10 tag")
    }

    func testApplyReplacementsSkipsEmptyKey() {
        let result = TextPostProcessor.applyReplacements(
            "hello",
            replacements: [("", "x")]
        )
        XCTAssertEqual(result, "hello")
    }
}
