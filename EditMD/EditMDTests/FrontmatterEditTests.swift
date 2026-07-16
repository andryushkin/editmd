import XCTest
@testable import EditMD

final class FrontmatterEditTests: XCTestCase {

    // MARK: - replaceFrontmatterScalar

    func testReplaceScalarPreservesOrderIndentCommentsAndUnknown() {
        let doc = """
        ---
        # header comment
        title: Old
        priority: HIGH  # keep me
        unknown: stay

        tags: [a]
        ---
        Body line
        """
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "New")
        XCTAssertEqual(next, """
        ---
        # header comment
        title: New
        priority: HIGH  # keep me
        unknown: stay

        tags: [a]
        ---
        Body line
        """)
    }

    func testReplaceScalarPreservesTrailingComment() {
        let doc = "---\ntitle: Old  # note\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "New")
        XCTAssertEqual(next, "---\ntitle: New  # note\n---\n")
    }

    func testReplaceScalarCRLF() {
        let doc = "---\r\ntitle: Old\r\n---\r\nBody"
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "New")
        XCTAssertEqual(next, "---\r\ntitle: New\r\n---\r\nBody")
    }

    func testReplaceScalarBodyUnchangedByteForByte() {
        let body = "\n\n# Heading\n\nParagraph with **bold**.\n"
        let doc = "---\ntitle: A\n---" + body
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "B")!
        XCTAssertTrue(next.hasSuffix(body))
        XCTAssertEqual(String(next.dropFirst(next.count - body.count)), body)
    }

    func testReplaceScalarRoundTripParse() {
        let doc = "---\ntitle: A\ntags: [x]\n---\n# H\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "B")!
        guard let fm = frontmatterRange(in: next) else {
            return XCTFail("frontmatter lost")
        }
        let props = parseFrontmatterProperties(
            (next as NSString).substring(with: fm.body))
        XCTAssertEqual(props.first(where: { $0.key == "title" })?.value, "B")
        XCTAssertEqual(props.first(where: { $0.key == "tags" })?.items, ["x"])
        XCTAssertTrue(next.hasSuffix("# H\n"))
    }

    // MARK: - refusals

    func testRefuseListAsScalar() {
        let doc = "---\ntags: [a, b]\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "tags", newValue: "x"))
    }

    func testRefuseBlockStructureAsScalar() {
        let doc = "---\nnested:\n  sub: v\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "nested", newValue: "x"))
    }

    func testRefuseMultilineValue() {
        let doc = "---\ntitle: A\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "title",
                                              newValue: "line1\nline2"))
    }

    func testRefuseDuplicateKey() {
        let doc = "---\ntitle: A\ntitle: B\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "title", newValue: "C"))
        XCTAssertNil(removeFrontmatterField(document: doc, key: "title"))
    }

    func testRefuseMissingKey() {
        let doc = "---\ntitle: A\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "nope", newValue: "x"))
    }

    func testRefuseAnchorLikeValueShape() {
        // Existing anchor-style value is complex — do not rewrite.
        let doc = "---\nref: *alias\n---\n"
        XCTAssertNil(replaceFrontmatterScalar(document: doc, key: "ref", newValue: "x"))
    }

    func testCommentLineIsNotAKey() {
        // Full-line comment must not be treated as the `title` field.
        let doc = "---\n# title: fake\ntitle: real\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title", newValue: "ok")
        XCTAssertEqual(next, "---\n# title: fake\ntitle: ok\n---\n")
    }

    // MARK: - escaping

    func testEscapeColonInValue() {
        let doc = "---\ntitle: x\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title",
                                            newValue: "a: b")!
        XCTAssertEqual(next, "---\ntitle: \"a: b\"\n---\n")
    }

    func testEscapeHashInValue() {
        let doc = "---\ntitle: x\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title",
                                            newValue: "c# sharp")!
        XCTAssertEqual(next, "---\ntitle: \"c# sharp\"\n---\n")
    }

    func testEscapeQuotesAndUnicode() {
        let doc = "---\ntitle: x\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title",
                                            newValue: "привет \"мир\" 😀")!
        XCTAssertEqual(next, "---\ntitle: \"привет \\\"мир\\\" 😀\"\n---\n")
    }

    func testEscapeLeadingTrailingSpaces() {
        let doc = "---\ntitle: x\n---\n"
        let next = replaceFrontmatterScalar(document: doc, key: "title",
                                            newValue: "  padded  ")!
        XCTAssertEqual(next, "---\ntitle: \"  padded  \"\n---\n")
    }

    func testPlainLiteralBoolNumber() {
        XCTAssertEqual(encodeYAMLScalar("true", plainLiteral: true), "true")
        XCTAssertEqual(encodeYAMLScalar("42", plainLiteral: true), "42")
        // Auto mode quotes ambiguous tokens so string fields stay strings.
        XCTAssertEqual(encodeYAMLScalar("true"), "\"true\"")
        XCTAssertEqual(encodeYAMLScalar("42"), "\"42\"")
    }

    func testReplacePlainScalarBool() {
        let doc = "---\ndraft: false\n---\n"
        let next = replaceFrontmatterPlainScalar(document: doc, key: "draft",
                                                 newValue: "true")
        XCTAssertEqual(next, "---\ndraft: true\n---\n")
    }

    // MARK: - lists

    func testReplaceFlowListPreservesStyleAndComment() {
        let doc = "---\ntags: [a, b]  # note\n---\n"
        let next = replaceFrontmatterList(document: doc, key: "tags",
                                          items: ["x", "y"])
        XCTAssertEqual(next, "---\ntags: [x, y]  # note\n---\n")
    }

    func testReplaceBlockListPreservesStyle() {
        let doc = """
        ---
        tags:
          - a
          - b
        title: T
        ---
        """
        let next = replaceFrontmatterList(document: doc, key: "tags",
                                          items: ["x", "y"])
        XCTAssertEqual(next, """
        ---
        tags:
          - x
          - y
        title: T
        ---
        """)
    }

    func testReplaceListEmptyFlow() {
        let doc = "---\ntags: [a]\n---\n"
        let next = replaceFrontmatterList(document: doc, key: "tags", items: [])
        XCTAssertEqual(next, "---\ntags: []\n---\n")
    }

    func testReplaceListEmptyBlock() {
        let doc = "---\ntags:\n  - a\n---\n"
        let next = replaceFrontmatterList(document: doc, key: "tags", items: [])
        XCTAssertEqual(next, "---\ntags:\n---\n")
    }

    func testUpgradeScalarToFlowList() {
        let doc = "---\ntags: solo\n---\n"
        let next = replaceFrontmatterList(document: doc, key: "tags",
                                          items: ["a", "b"])
        XCTAssertEqual(next, "---\ntags: [a, b]\n---\n")
    }

    func testRefuseComplexAsList() {
        let doc = "---\nnested:\n  sub: v\n---\n"
        XCTAssertNil(replaceFrontmatterList(document: doc, key: "nested",
                                            items: ["a"]))
    }

    // MARK: - insert / remove

    func testInsertCreatesFrontmatter() {
        let doc = "# Hello\n"
        let next = insertFrontmatterScalar(document: doc, key: "title", value: "A")
        XCTAssertEqual(next, "---\ntitle: A\n---\n\n# Hello\n")
    }

    func testInsertIntoExistingFrontmatter() {
        let doc = "---\ntitle: A\n---\nbody\n"
        let next = insertFrontmatterScalar(document: doc, key: "draft", value: "false")
        // "false" is quoted in auto mode (string-safe).
        XCTAssertEqual(next, "---\ntitle: A\ndraft: \"false\"\n---\nbody\n")
    }

    func testInsertIntoEmptyFrontmatter() {
        let doc = "---\n---\nbody"
        let next = insertFrontmatterScalar(document: doc, key: "title", value: "A")
        XCTAssertEqual(next, "---\ntitle: A\n---\nbody")
    }

    func testInsertRefusesDuplicate() {
        let doc = "---\ntitle: A\n---\n"
        XCTAssertNil(insertFrontmatterScalar(document: doc, key: "title", value: "B"))
    }

    func testInsertList() {
        let doc = "---\ntitle: A\n---\n"
        let next = insertFrontmatterList(document: doc, key: "tags", items: ["a", "b"])
        XCTAssertEqual(next, "---\ntitle: A\ntags: [a, b]\n---\n")
    }

    func testRemoveFieldMiddle() {
        let doc = "---\na: 1\nb: 2\nc: 3\n---\n"
        let next = removeFrontmatterField(document: doc, key: "b")
        XCTAssertEqual(next, "---\na: 1\nc: 3\n---\n")
    }

    func testRemoveLastFieldKeepsEmptyBlock() {
        let doc = "---\ntitle: A\n---\nbody\n"
        let next = removeFrontmatterField(document: doc, key: "title")
        XCTAssertEqual(next, "---\n---\nbody\n")
        XCTAssertNotNil(frontmatterRange(in: next!))
    }

    func testRemoveBlockList() {
        let doc = "---\ntags:\n  - a\n  - b\ntitle: T\n---\n"
        let next = removeFrontmatterField(document: doc, key: "tags")
        XCTAssertEqual(next, "---\ntitle: T\n---\n")
    }

    func testRemoveRefusesComplex() {
        let doc = "---\nnested:\n  sub: v\n---\n"
        XCTAssertNil(removeFrontmatterField(document: doc, key: "nested"))
    }

    // MARK: - classify

    func testClassifyKinds() {
        let doc = """
        ---
        title: Hello
        count: 3
        draft: true
        published: 2024-01-15
        tags: [a, b]
        aliases:
          - Alt
        nested:
          x: 1
        ---
        """
        let fields = classifyFrontmatterFields(in: doc)
        let byKey = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        XCTAssertEqual(byKey["title"]?.kind, .string)
        XCTAssertEqual(byKey["count"]?.kind, .number)
        XCTAssertEqual(byKey["draft"]?.kind, .bool)
        XCTAssertEqual(byKey["published"]?.kind, .date)
        XCTAssertEqual(byKey["tags"]?.kind, .tags)
        XCTAssertEqual(byKey["aliases"]?.kind, .aliases)
        XCTAssertEqual(byKey["nested"]?.kind, .complex)
        XCTAssertEqual(byKey["nested"]?.isEditable, false)
        XCTAssertEqual(byKey["title"]?.isEditable, true)
        XCTAssertNotNil(byKey["title"]?.utf16Offset)
    }

    func testClassifyNoFrontmatter() {
        XCTAssertTrue(classifyFrontmatterFields(in: "# No fm\n").isEmpty)
    }

    func testFieldUTF16OffsetPointsAtKeyLine() {
        let doc = "---\ntitle: A\n---\n"
        let offset = frontmatterFieldUTF16Offset(in: doc, key: "title")
        XCTAssertEqual(offset, 4) // after "---\n"
        let slice = (doc as NSString).substring(from: offset!)
        XCTAssertTrue(slice.hasPrefix("title: A"))
    }
}
