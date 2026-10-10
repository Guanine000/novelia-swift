#!/usr/bin/env python3
"""Test production release matching and startup checks with synthetic HTTP responses."""
from pathlib import Path
import subprocess
import tempfile
source = (Path(__file__).resolve().parents[1] / 'iOSApp/NoveliaApp.swift').read_text()
code = 'import Foundation\nimport Combine\n' + source[source.index('/// Stable release numbers only;'):source.index('struct SyncedBlockedTag:')]
code += r'''
func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
final class MockProtocol: URLProtocol {
    static var hits = 0
    static var status = 200
    static var payload = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hits += 1
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "public API needs no token")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Tests {
 @MainActor static func main() async {
    check(NoveliaReleaseVersion("v0.10.0")! > NoveliaReleaseVersion("0.9.9")!, "numeric comparison")
    for invalid in ["0.8.1-test.1", "v0.8", "0.x.0", "", "0.8.1+34"] { check(NoveliaReleaseVersion(invalid) == nil, "invalid version") }
    let name = "NoveliaUpdatesTest-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    MockProtocol.payload = #"{"tag_name":"v0.8.1","html_url":"https://github.com/Guanine000/novelia-swift/releases/tag/v0.8.1","draft":false,"prerelease":false}"#
    let store = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
    await store.check(); check(store.release?.version?.display == "0.8.1", "new stable offered")
    await store.check(); check(MockProtocol.hits == 1, "once per launch")
    store.ignore(store.release!); check(store.release == nil, "ignore closes alert")
    let nextLaunch = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
    await nextLaunch.check(); check(nextLaunch.release == nil, "ignored persists")
    MockProtocol.payload = MockProtocol.payload.replacingOccurrences(of: "0.8.1", with: "0.8.2")
    await nextLaunch.check(force: true); check(nextLaunch.release != nil, "later release offered")
    defaults.set(false, forKey: NoveliaUpdateStore.enabledKey)
    let hits = MockProtocol.hits
    await nextLaunch.check(force: true); check(MockProtocol.hits == hits, "disabled avoids HTTP")
    defaults.set(true, forKey: NoveliaUpdateStore.enabledKey)
    nextLaunch.release = nil
    MockProtocol.status = 403
    await nextLaunch.check(force: true); check(nextLaunch.release == nil, "HTTP error silent")
    MockProtocol.status = 200; MockProtocol.payload = "invalid json"
    await nextLaunch.check(force: true); check(nextLaunch.release == nil, "malformed response silent")
    let release = NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: "https://github.com/Guanine000/novelia-swift/releases/tag/v0.8.2", draft: false, prerelease: false)
    check(!release.shouldOffer(current: "0.8.2", ignored: ""), "equal suppressed")
    check(!release.shouldOffer(current: "0.9.0", ignored: ""), "downgrade suppressed")
    check(!NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: "https://example.com/download", draft: false, prerelease: false).shouldOffer(current: "0.8.0", ignored: ""), "untrusted URL suppressed")
    check(!NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: release.html_url, draft: false, prerelease: true).shouldOffer(current: "0.8.0", ignored: ""), "prerelease suppressed")
    print("Release update checks passed: version ordering, ignore persistence, launch frequency, switch, HTTP/JSON failures")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='NoveliaReleaseChecks-') as directory:
    root = Path(directory); swift = root / 'Checks.swift'; swift.write_text(code)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(root/'cache'), str(swift), '-o', str(root/'checks')], check=True)
    subprocess.run([str(root/'checks')], check=True)
