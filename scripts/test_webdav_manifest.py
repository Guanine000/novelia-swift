#!/usr/bin/env python3
"""Check that the production WebDAV manifest decodes older manifests and round-trips synced records.

The merge rules themselves are covered by Tests/NoveliaIOSCoreTests/SyncMergeTests.swift; the
manifest type stays in the app because it holds app-only book records, stubbed here.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
webdav = (root / 'iOSApp/WebDAVSync.swift').read_text()
sync = (root / 'Sources/NoveliaIOSCore/SyncMerge.swift').read_text()
library = (root / 'Sources/NoveliaIOSCore/LibraryOrganizer.swift').read_text()
code = 'import Foundation\nimport Combine\n'
code += 'struct DownloadedWebNovel: Codable {}\nstruct LocalWenkuEPUB: Codable {}\n'
code += sync[sync.index('struct SyncedReadingPosition:'):]
code += library[library.index('enum LibrarySortField:'):]
code += webdav[webdav.index('private struct WebDAVAsset:'):webdav.index('private enum WebDAVSyncError:')]
code += r'''
@main struct Tests {
 static func main() throws {
  let legacy = try JSONDecoder().decode(WebDAVManifest.self, from: Data(#"{"version":1,"webBooks":[],"wenkuBooks":[],"positions":{}}"#.utf8))
  precondition(legacy.blockedTags == nil && legacy.backgrounds == nil && legacy.fonts == nil && legacy.librarySeries == nil, "older manifests decode without newer records")
  var manifest = legacy
  manifest.blockedTags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: Date(timeIntervalSince1970: 100))]
  manifest.fonts = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: false, updatedAt: Date(timeIntervalSince1970: 100))]
  manifest.positions = ["web:a": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: Date(timeIntervalSince1970: 100))]
  manifest.positions["txt:h"] = SyncedReadingPosition(chapterIndex: 4, fraction: nil, updatedAt: Date(timeIntervalSince1970: 100), chapterOffset: 80, unit: 9, unitCount: 120)
  var series = LibrarySeriesState()
  series.createSeries(named: "系列", now: Date(timeIntervalSince1970: 100), id: "s1")
  series.assign(book: "wenku:1", to: "s1", now: Date(timeIntervalSince1970: 101))
  manifest.librarySeries = series
  let roundtrip = try JSONDecoder().decode(WebDAVManifest.self, from: JSONEncoder().encode(manifest))
  precondition(roundtrip.blockedTags == manifest.blockedTags, "blocked tags round-trip")
  precondition(roundtrip.fonts?["hash"]?.format == "ttf", "fonts round-trip")
  precondition(roundtrip.positions == manifest.positions, "positions round-trip")
  precondition(roundtrip.librarySeries == series, "library series round-trip")
  precondition(roundtrip.positions["txt:h"]?.unit == 9, "TXT paged unit round-trips")
  print("WebDAV manifest passed: legacy decode and synced record round-trip")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='NoveliaWebDAVManifest-') as tmp:
    path = Path(tmp)
    (path / 'Checks.swift').write_text(code)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
