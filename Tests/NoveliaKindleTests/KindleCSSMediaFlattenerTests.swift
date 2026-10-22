import XCTest
@testable import NoveliaKindle

/// `amzn-*` 媒体查询按 Kindle（KF8）视角展开。
final class KindleCSSMediaFlattenerTests: XCTestCase {
    func testEvaluatesKindleConditions() {
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-kf8"), .always)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate(" AMZN-KF8 "), .always)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-et"), .always)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-mobi"), .never)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-mobi7"), .never)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("not amzn-kf8"), .never)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("not amzn-mobi"), .always)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-kf8, amzn-mobi"), .always)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-mobi, print"), .reduced("print"))
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("screen"), .unchanged)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-foo"), .unchanged)
    }

    func testKeepsStandardConditionsCombinedWithKindleOnes() {
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-kf8 and (orientation: portrait)"),
                       .reduced("(orientation: portrait)"))
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("only screen and amzn-kf8 and (min-width: 600px)"),
                       .reduced("only screen and (min-width: 600px)"))
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("amzn-mobi and (orientation: portrait)"), .never)
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("not amzn-kf8 and (orientation: portrait)"),
                       .reduced("not all and (orientation: portrait)"))
        XCTAssertEqual(KindleCSSMediaFlattener.evaluate("not screen and amzn-kf8"), .reduced("not screen"))
    }

    func testFlattensBlocksInPlace() {
        let css = "p { margin: 0 }\n@media amzn-kf8 { p { margin: 1em } }\n@media amzn-mobi { p { margin: 2em } }\nh1 { color: red }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(css),
                       "p { margin: 0 }\n p { margin: 1em } \n\nh1 { color: red }")
    }

    func testReducesCombinedQueriesAndKeepsOthers() {
        let css = "@media amzn-kf8 and (orientation: landscape) { .a { x: 1 } }@media screen { .b { y: 2 } }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(css),
                       "@media (orientation: landscape) { .a { x: 1 } }@media screen { .b { y: 2 } }")
    }

    func testHandlesNestedBlocks() {
        let css = "@media amzn-kf8 { @supports (display: flex) { .a { display: flex } } @media amzn-mobi { .b { c: d } } }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(css),
                       " @supports (display: flex) { .a { display: flex } }  ")
    }

    func testIgnoresMediaTextInsideCommentsAndStrings() {
        let css = "/* @media amzn-mobi { a {} } */ .q::before { content: \"@media amzn-mobi { }\" }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(css), css)
    }

    func testReturnsOriginalWhenStructureIsBroken() {
        let unclosedBlock = "@media amzn-kf8 { p { margin: 1em }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(unclosedBlock), unclosedBlock)
        let unclosedComment = "@media amzn-mobi { p {} } /* tail"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(unclosedComment), unclosedComment)
    }

    func testFlattensMarkupStylesAndMediaAttributes() {
        let html = """
            <html><head>\
            <link href="kf8.css" rel="stylesheet" type="text/css" media="amzn-kf8"/>\
            <link href="mobi.css" rel="stylesheet" type="text/css" media="amzn-mobi"/>\
            <link href="print.css" rel="stylesheet" media="print"/>\
            <style type="text/css">@media amzn-kf8 { .a { b: c } }</style>\
            <style media="amzn-mobi">.old { x: y }</style>\
            </head><body/></html>
            """
        XCTAssertEqual(KindleCSSMediaFlattener.flattenMarkup(html), """
            <html><head>\
            <link href="kf8.css" rel="stylesheet" type="text/css"/>\
            <link href="print.css" rel="stylesheet" media="print"/>\
            <style type="text/css"> .a { b: c } </style>\
            </head><body/></html>
            """)
    }

    func testOutputIsDeterministic() {
        let css = "@media amzn-kf8 { .a { b: c } } @media amzn-mobi { .d { e: f } }"
        XCTAssertEqual(KindleCSSMediaFlattener.flatten(css), KindleCSSMediaFlattener.flatten(css))
    }
}
