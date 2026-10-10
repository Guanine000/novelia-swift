#!/usr/bin/env python3
"""Check production notice URL routing with synthetic URLs; no network requests."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'iOSApp/ForumViews.swift').read_text()
route = s[s.index('private enum ForumNoticeDestination'):s.index('private struct ForumRulesView')]
checks = r'''
func check(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { fatalError(message) } }
check(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/c/announcements")!) == .category("announcements", ""), "announcement route")
check(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/c/feedback/")!) == .category("feedback", ""), "feedback route")
var url = URLComponents(string: "https://forum.novelia.cc/c/novel")!
url.queryItems = [URLQueryItem(name: "q", value: "求书集中贴")]
check(ForumNoticeDestination(url: url.url!) == .category("novel", "求书集中贴"), "preserve decoded search")
check(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/rules")!) == .rules, "rules route")
for raw in ["https://example.com/rules", "https://forum.novelia.cc.example.com/c/novel", "https://forum.novelia.cc@evil.example/rules", "https://forum.novelia.cc/c/unknown", "https://forum.novelia.cc:8443/rules", "file:///rules", "https://forum.novelia.cc/p/42"] {
 check(ForumNoticeDestination(url: URL(string: raw)!) == nil, "unexpected URL interception")
}
print("Notice routes passed: categories, decoded query, rules and external URL fallback")
'''
with tempfile.TemporaryDirectory(prefix='ForumNoticeRoutes-') as tmp:
 p = Path(tmp)
 (p / 'main.swift').write_text('import Foundation\n' + route + checks)
 subprocess.run(['swiftc', '-module-cache-path', str(p / 'cache'), str(p / 'main.swift'), '-o', str(p / 'check')], check=True)
 subprocess.run([str(p / 'check')], check=True)
