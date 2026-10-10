#!/usr/bin/env python3
"""Exercise the actual renewal coordinator with synthetic JWTs and HTTP responses."""
from pathlib import Path
import subprocess
import tempfile
source = Path('Sources/NoveliaIOSCore/NoveliaAPIClient.swift').read_text()
actor = source[source.index('public actor NoveliaSessionRenewal'):]
tests = r'''
import Foundation
func jwt(_ subject: String, _ exp: Double) -> String {
 let bytes = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": exp])
 return "header." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}
actor Counter { var count = 0; func bump() { count += 1 } }
final class MockHTTP: URLProtocol {
 static var calls = 0
 static var status = 401
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  Self.calls += 1
  let code = Self.calls == 1 ? Self.status : 200
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data())
  client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Tests {
 static func main() async throws {
  let expired = jwt("alice", 1), fresh = jwt("alice", Date().timeIntervalSince1970 + 3600)
  let counter = Counter(), coordinator = NoveliaSessionRenewal()
  await coordinator.register(app: "n") { await counter.bump(); try? await Task.sleep(nanoseconds: 100_000_000); return fresh }
  async let a = coordinator.token(app: "n", current: expired)
  async let b = coordinator.token(app: "n", current: expired)
  let values = await (a,b); assert(values.0 == fresh && values.1 == fresh)
  let calls = await counter.count; assert(calls == 1)
  let untouched = await coordinator.token(app: "f", current: expired); assert(untouched == expired)
  let anonymous = await coordinator.token(app: "n", current: nil); assert(anonymous == nil)
  await coordinator.register(app: "n") { nil }
  let offline = await coordinator.token(app: "n", current: expired); assert(offline == expired)
  await coordinator.register(app: "n") { jwt("bob", Date().timeIntervalSince1970 + 3600) }
  let switched = await coordinator.token(app: "n", current: expired); assert(switched == expired)
  let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
  let session = URLSession(configuration: config), request = URLRequest(url: URL(string: "https://example.invalid/api")!)
  await NoveliaSessionRenewal.shared.register(app: "n") { jwt("alice", Date().timeIntervalSince1970 + 7200) }
  let result = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { fresh })
  assert((result.1 as! HTTPURLResponse).statusCode == 200 && MockHTTP.calls == 2)
  MockHTTP.calls = 0; MockHTTP.status = 500
  _ = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { fresh })
  assert(MockHTTP.calls == 1)
  MockHTTP.calls = 0; MockHTTP.status = 401
  _ = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { nil })
  assert(MockHTTP.calls == 1)
  print("Session renewal regression passed: expired recovery, concurrent renewal, account isolation, transient failure retention, bounded 401 retry")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='novelia-session-test-') as directory:
    path = Path(directory)
    (path/'Coordinator.swift').write_text('import Foundation\n'+actor)
    (path/'Tests.swift').write_text(tests)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(path/'cache'),str(path/'Coordinator.swift'),str(path/'Tests.swift'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
