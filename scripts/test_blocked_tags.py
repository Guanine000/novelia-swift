#!/usr/bin/env python3
"""Verify production tag blocking, persistence and known library metadata."""
from pathlib import Path
import tempfile
import subprocess
source = (Path(__file__).resolve().parents[1]/'iOSApp/NoveliaApp.swift').read_text()
code = 'import Foundation\nimport Combine\n' + source[source.index('struct SyncedBlockedTag:'):source.index('struct BlockedTagsView: View')]
webdav = (Path(__file__).resolve().parents[1]/'iOSApp/WebDAVSync.swift').read_text()
code += '\nstruct DownloadedWebNovel: Codable {}\nstruct LocalWenkuEPUB: Codable {}\nstruct SyncedReadingPosition: Codable {}\n'
code += source[source.index('struct SyncedReaderBackground:'):source.index('@MainActor\nextension ReaderBackgroundStore')]
code += source[source.index('struct SyncedImportedFont:'):]
code += webdav[webdav.index('private struct WebDAVAsset:'):webdav.index('private enum WebDAVSyncError:')]
code += r'''
@main struct Tests {
 @MainActor static func main() {
  let name = "BlockedTagsTest-\(UUID())"; let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let store = BlockedTagsStore(defaults: defaults)
  store.add("  标签A \n"); store.add("标签A"); store.add("  ")
  precondition(store.tags == ["标签A"])
  precondition(store.hides(["普通", "标签A"]))
  precondition(!store.hides(["标签AB"]) && !store.hides([]))
  store.rememberWenku(id: "synthetic-book", tags: ["标签A"])
  let restored = BlockedTagsStore(defaults: defaults)
  precondition(restored.tags == ["标签A"] && restored.hides(restored.wenkuTags["synthetic-book"]!))
  restored.remove("标签A")
  precondition(!restored.hides(["标签A"]) && BlockedTagsStore(defaults: defaults).tags.isEmpty)
  let legacy = try! JSONDecoder().decode(WebDAVManifest.self, from: Data(#"{"version":1,"webBooks":[],"wenkuBooks":[],"positions":{}}"#.utf8))
  precondition(legacy.blockedTags == nil)
  var manifest = legacy; manifest.blockedTags = restored.syncStates
  let roundtrip = try! JSONDecoder().decode(WebDAVManifest.self, from: JSONEncoder().encode(manifest))
  precondition(roundtrip.blockedTags == restored.syncStates)
  let old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
  let font = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: false, updatedAt: old)]
  let deletedFont = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: true, updatedAt: newer)]
  precondition(SyncedImportedFont.merged(font, deletedFont)["hash"]!.deleted)
  precondition(SyncedImportedFont.merged(deletedFont, font)["hash"]!.deleted)
  let tied = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: true, updatedAt: old)]
  precondition(SyncedImportedFont.merged(font, tied)["hash"]!.deleted && SyncedImportedFont.merged(tied, font)["hash"]!.deleted)
  let remote = ["标签B": SyncedBlockedTag(blocked: true, updatedAt: old)]
  restored.applySynced(remote); precondition(restored.contains("标签B"))
  let unblocked = ["标签B": SyncedBlockedTag(blocked: false, updatedAt: newer)]
  restored.applySynced(unblocked); precondition(!restored.contains("标签B"))
  restored.applySynced(remote); precondition(!restored.contains("标签B"))
  precondition(BlockedTagsStore(defaults: defaults).syncStates["标签B"]?.blocked == false)
  precondition(BlockedTagsStore.merged(remote, unblocked) == BlockedTagsStore.merged(unblocked, remote))
  let equal = ["标签B": SyncedBlockedTag(blocked: false, updatedAt: old)]
  precondition(BlockedTagsStore.merged(remote, equal) == BlockedTagsStore.merged(equal, remote))
  print("Tag blocking passed: exact match, trimming, duplicates, persistence, removal and library metadata")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='NoveliaBlockedTags-') as tmp:
    root = Path(tmp); (root/'Checks.swift').write_text(code)
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(root/'cache'),str(root/'Checks.swift'),'-o',str(root/'checks')],check=True)
    subprocess.run([str(root/'checks')],check=True)
