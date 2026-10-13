import Foundation
import XCTest
@testable import NoveliaIOSCore

private final class PostEditMock: URLProtocol {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var failures: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        func expect(_ ok: Bool, _ message: String) { if !ok { Self.failures.append(message) } }
        expect(request.httpMethod == "PATCH", "method")
        expect(request.url?.absoluteString == "https://example.com/api/v1/post/42/", "path")
        expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "content type")
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                data.append(contentsOf: bytes.prefix(n))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        expect(body["categoryId"] as? Int == 7, "categoryId")
        expect(body["title"] as? String == "新标题", "title")
        expect(body["content"] as? String == "第一行\n第二行\n", "content kept verbatim")
        expect(body["tagIds"] as? [Int] == [3], "tagIds")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        let result: [String: Any] = Self.status == 200
            ? ["id": 42, "categoryId": 7, "title": "新标题", "content": body["content"] ?? "", "authorUsername": "test-author",
               "tags": [["id": 3, "name": "测试标签"]]]
            : ["message": "无权修改此帖子"]
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 编辑自己的论坛帖子（原 scripts/test_forum_post_edit.py）。
final class ForumAPITests: XCTestCase {
    func testUpdatePost() async throws {
        PostEditMock.count = 0; PostEditMock.status = 200; PostEditMock.failures = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PostEditMock.self]
        let api = ForumAPIClient(baseURL: URL(string: "https://example.com/api/v1/")!, session: URLSession(configuration: config))

        let post = try await api.updatePost(id: 42, categoryID: 7, title: "新标题", content: "第一行\n第二行\n", tagIDs: [3])
        XCTAssertEqual(post.id, 42)
        XCTAssertEqual(post.content, "第一行\n第二行\n")
        XCTAssertEqual(post.tags.map(\.id), [3])

        PostEditMock.status = 403
        do {
            _ = try await api.updatePost(id: 42, categoryID: 7, title: "新标题", content: "第一行\n第二行\n", tagIDs: [3])
            XCTFail("403 silently succeeded")
        } catch ForumAPIError.httpStatus(403, _) {}

        let count = PostEditMock.count
        do {
            _ = try await api.updatePost(id: 42, categoryID: 7, title: "", content: "文本")
            XCTFail("invalid title accepted")
        } catch ForumAPIError.invalidInput(_) {}
        XCTAssertEqual(PostEditMock.count, count, "validation happens before any request")
        XCTAssertEqual(PostEditMock.failures, [])
    }
}
