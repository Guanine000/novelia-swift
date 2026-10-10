#!/usr/bin/env python3
"""Exercise the real edit API against an in-process mock; no accounts or network writes."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/NoveliaIOSCore/ForumAPIClient.swift').read_text()
code = source + r'''
private enum NoveliaSessionRenewal {
    static func data(session: URLSession, request: URLRequest, app: String,
                     tokenProvider: @Sendable () -> String?) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
private final class Mock: URLProtocol {
    static var count = 0
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        precondition(request.httpMethod == "PATCH")
        precondition(request.url?.absoluteString == "https://example.com/api/v1/post/42/")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(body["categoryId"] as? Int == 7)
        precondition(body["title"] as? String == "新标题")
        precondition(body["content"] as? String == "第一行\n第二行\n")
        precondition(body["tagIds"] as? [Int] == [3])
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let result: [String: Any] = Self.status == 200 ? ["id": 42, "categoryId": 7, "title": "新标题", "content": body["content"]!, "authorUsername": "test-author", "tags": [["id": 3, "name": "测试标签"]]] : ["message": "无权修改此帖子"]
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main private struct Regression {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Mock.self]
        let api = ForumAPIClient(baseURL: URL(string: "https://example.com/api/v1/")!, session: URLSession(configuration: config))
        let post = try await api.updatePost(id: 42, categoryID: 7, title: "新标题", content: "第一行\n第二行\n", tagIDs: [3])
        precondition(post.id == 42 && post.content == "第一行\n第二行\n" && post.tags.map(\.id) == [3])
        Mock.status = 403
        do { _ = try await api.updatePost(id: 42, categoryID: 7, title: "新标题", content: "第一行\n第二行\n", tagIDs: [3]); fatalError("403 silently succeeded") }
        catch ForumAPIError.httpStatus(403, _) {}
        let count = Mock.count
        do { _ = try await api.updatePost(id: 42, categoryID: 7, title: "", content: "文本"); fatalError("invalid title accepted") }
        catch ForumAPIError.invalidInput(_) {}
        precondition(Mock.count == count)
        print("Post edit API passed: PATCH path/body, verbatim newlines/tags, returned post, 403 and validation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='NoveliaPostEdit-') as tmp:
    path = Path(tmp) / 'Regression.swift'; path.write_text(code)
    binary = Path(tmp) / 'regression'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(tmp) / 'ModuleCache'), str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
