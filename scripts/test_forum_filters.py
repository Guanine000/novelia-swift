#!/usr/bin/env python3
"""使用合成响应测试生产 API 与列表状态，不访问网络。"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
view = (root/'iOSApp/Features/Community/ForumStore.swift').read_text()
code = 'import Combine\n' + (root/'Sources/NoveliaIOSCore/Infrastructure/API/APIConfiguration.swift').read_text() + (root/'Sources/NoveliaIOSCore/Infrastructure/API/ForumAPIClient.swift').read_text()
services = (root/'Sources/NoveliaIOSCore/Domain/APIServices.swift').read_text()
code += services[services.index('public protocol ForumService'):services.index('@MainActor\nprotocol AccountSessionProviding')]
code += '\nextension ForumAPIClient: ForumService {}\n'
code += view[view.index('@MainActor\nfinal class ForumStore'):]
code += r'''
enum NoveliaForumSessionTokenVault { static func read() -> String? { nil } }
enum NoveliaRequestTimeout { static let api: TimeInterval = 30 }
enum NoveliaSessionRenewal {
 static func data(session: URLSession, request: URLRequest, app: String, tokenProvider: @Sendable () -> String?) async throws -> (Data, URLResponse) { try await session.data(for: request) }
}
final class Mock: URLProtocol {
 static var requests: [URL] = []
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  Self.requests.append(request.url!)
  let json = request.url!.path.contains("category") ? #"[{"id":1,"slug":"novel","tags":[{"id":11,"name":"书单"},{"id":12,"name":"工具"},{"id":13,"name":"教程"},{"id":14,"name":"资源"},{"id":99,"name":"其他"}]},{"id":2,"slug":"announcements","tags":[{"id":11,"name":"书单"}]},{"id":3,"slug":"feedback","tags":[]}]"# : #"{"items":[],"total":100}"#
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
func query() -> [String:String] { Dictionary(uniqueKeysWithValues: URLComponents(url: Mock.requests.last!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }) }
@main struct Tests {
 @MainActor static func main() async throws {
  let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Mock.self]
  let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
  let api = ForumAPIClient(baseURL: URL(string: "https://example.com/api/v1/")!, session: session)
  let store = ForumStore(api: api)
  await store.loadCategories(); await store.selectCategory("novel")
  precondition(store.filterTags.map(\.name) == ["书单", "工具", "教程", "资源"])
  for tag in store.filterTags {
   store.selectedTagID = tag.id
   await store.loadPosts()
   precondition(query()["tag"] == String(tag.id) && query()["page"] == "1")
  }
  store.selectedTagID = nil; await store.loadPosts(); precondition(query()["tag"] == nil)
  for category in ["novel", "announcements", "feedback"] {
   await store.selectCategory(category)
   precondition(store.selectedTagID == nil && store.page == 0)
   if category != "novel" { precondition(store.filterTags.isEmpty) }
   for sort in ForumSort.allCases {
    store.sort = sort; await store.loadPosts()
    precondition(query()["sort"] == sort.rawValue && query()["category"] == category)
   }
  }
  precondition(ForumSort.allCases.map(\.rawValue) == ["active", "newest", "updated", "views", "comments"])
  await store.selectCategory("novel"); store.selectedTagID = 11
  await store.loadPosts(page: 2); precondition(query()["page"] == "3" && query()["tag"] == "11")
  await store.selectSource(.favorites)
  precondition(store.selectedTagID == nil && store.filterTags.isEmpty && query()["tag"] == nil && query()["sort"] == nil)
  await store.selectSource(.all); precondition(store.filterTags.count == 4 && query()["tag"] == nil)
  print("Forum filters passed: four tags, five sorts across three categories, clearing, pagination and favorites return")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='NoveliaForumFilters-') as tmp:
    path = Path(tmp)/'Checks.swift'; path.write_text(code)
    binary = Path(tmp)/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(Path(tmp)/'cache'),str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
