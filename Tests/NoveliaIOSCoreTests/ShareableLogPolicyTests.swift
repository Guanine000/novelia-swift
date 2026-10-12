import XCTest
@testable import NoveliaIOSCore

final class ShareableLogPolicyTests: XCTestCase {
    func testReviewedDiagnosticsKeepUsefulNumbers() {
        let text = "TXT chapters parsed; lines=400, chapters=12, elapsedMs=3"
        XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "txt", text: text), text)
        let error = "Novel EPUB request failed before receiving an HTTP response; domain=NSURLErrorDomain, code=-1009, elapsedMs=45"
        XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "novel-download", text: error), error)
    }

    func testSystemAndUnreviewedMessagesAreExcluded() {
        for category in ["txt", "unknown", "lifecycle"] {
            for secret in ["B6713B51-406C-49F6-B152-CAF6527A3322", "/private/var/mobile/Containers/Data/Application/id/book.epub", "https://host.test/path?token=secret", "Authorization: Bearer secret", "person@example.test", "我的书名与正文"] {
                XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: secret))
            }
        }
        XCTAssertNil(ShareableLogPolicy.message(subsystem: "com.apple.network", category: "txt", text: "TXT decode succeeded; bytes=123, elapsedMs=2"))
    }

    func testKnownPrefixesNeverCopyFreeText() {
        let secret = "UUID=B6713B51-406C-49F6-B152-CAF6527A3322 token=secret /Users/name/book.epub"
        for (category, prefix) in [("enginediag", "ENGINE_DIAG "), ("epubcontainer", "TOC nav entries="), ("novel-download", "Starting novel EPUB download;")] {
            let output = ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: prefix + secret)
            XCTAssertNotNil(output)
            XCTAssertFalse(output?.contains(secret) ?? true)
        }
    }

    func testSuffixNewlineAndForgedFieldsCannotPass() {
        let valid = "TXT decode succeeded; bytes=123, elapsedMs=2"
        for suffix in ["\n", "\nAuthorization: Bearer secret", " UUID=secret", "\u{2028}secret"] {
            XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "txt", text: valid + suffix))
        }
        XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "novel-download", text: "Novel EPUB request failed before receiving an HTTP response; domain=person@example.test, code=-1, elapsedMs=2"))
    }
}
