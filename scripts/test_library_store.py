#!/usr/bin/env python3
"""Exercise production display/hash methods with isolated files; never touches a user's library."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'iOSApp/Features/Library/LibraryStore.swift').read_text()
display = source[source.index('    func displayBooks'):source.index('    func status(for')]
identity = source[source.index('    nonisolated private static func identity'):source.index('    private func hash(for')]
refresh = source[source.index('    func refreshHashes'):source.index('    // MARK: 排序设置')]
forget = source[source.index('    func forget(keys:'):source.index('    /// WebDAV 合并后的系列状态。')]
fixture = 'import Foundation\n'
fixture += r'''
struct LibraryBook { let key: String; let fileURL: URL; var categoryTitle = "文库"; let positionPrefix = "epub:"; var importedAt = Date.distantPast; var cloudFileHash: String? = nil; var isCloudOnly: Bool { cloudFileHash != nil } }
enum FileContentHash {
 static let lock = NSLock(); static var count = 0
 static func sha256(_ url: URL) throws -> String {
  precondition(!Thread.isMainThread, "hash must run off main thread")
  lock.lock(); count += 1; lock.unlock()
  Thread.sleep(forTimeInterval: 0.01)
  return String(decoding: try Data(contentsOf: url), as: UTF8.self)
 }
 static var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@MainActor final class HashStore {
 var series = LibrarySeriesState()
 var hashRefreshGeneration = 0
 var hashes: [String: String] = [:]
 var publications = 0
 var hashByBook: [String: String] = [:] { didSet { publications += 1 } }
 let defaults = UserDefaults(suiteName: "NoveliaLibraryRegression-" + UUID().uuidString)!
 enum Key { static let hashes = "hashes" }
 var lastOpened: [String: Date] = [:]; var lastOpenedWrites = 0
 var prunes: [Set<String>] = []
 func pruneOrphanedState(books: [LibraryBook], keepingHashes: Set<String>) { prunes.append(keepingHashes) }
 func save(_ state: LibrarySeriesState) { series = state }
 func persistLastOpened() { lastOpenedWrites += 1 }
'''
fixture += display + identity + refresh + forget + '\n}\n'
fixture += (root / 'Sources/NoveliaIOSCore/Features/Library/LibraryOrganizer.swift').read_text()
fixture += r'''
@main struct Checks {
 @MainActor static func main() async throws {
  let fm = FileManager.default
  let directory = fm.temporaryDirectory.appendingPathComponent("NoveliaLibraryRegression-" + UUID().uuidString)
  try fm.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: directory) }
  let targets = try (0..<30).map { index in
   let url = directory.appendingPathComponent("hash-\(index).txt")
   try Data("content-\(index)".utf8).write(to: url)
   return LibraryBook(key: "book-\(index)", fileURL: url)
  }
  let loading = HashStore()
  loading.hashByBook = ["retained": "hash"]
  let publications = loading.publications
  await loading.refreshHashes(for: targets, librariesReady: false)
  precondition(loading.prunes.isEmpty && loading.hashByBook == ["retained": "hash"] && loading.publications == publications,
               "an incomplete library must not clear hash cache or orphaned reading state")
  let hashes = HashStore()
  await hashes.refreshHashes(for: targets)
  precondition(hashes.hashByBook.count == 30 && hashes.publications == 1, "one batch publication")
  precondition(hashes.prunes.count == 1 && hashes.prunes[0].count == 30, "cleanup runs with every local hash")
  let unreadable = LibraryBook(key: "missing", fileURL: directory.appendingPathComponent("missing.txt"))
  let partial = HashStore()
  await partial.refreshHashes(for: targets + [unreadable])
  precondition(partial.prunes.isEmpty, "no cleanup while a local book has no hash")
  var cloudOnly = LibraryBook(key: "cloud", fileURL: directory.appendingPathComponent("cloud.txt")); cloudOnly.cloudFileHash = "cloud-hash"
  let withCloud = HashStore()
  await withCloud.refreshHashes(for: [targets[0], cloudOnly])
  precondition(withCloud.prunes.first?.contains("cloud-hash") == true, "cloud books keep their positions")
  let calls = FileContentHash.calls
  await hashes.refreshHashes(for: targets)
  precondition(FileContentHash.calls == calls && hashes.publications == 1, "cached batch does no hash or publish")
  let displayStore = HashStore()
  let duplicate = LibraryBook(key: "different-id", fileURL: targets[0].fileURL)
  await displayStore.refreshHashes(for: targets + [duplicate])
  precondition(displayStore.displayBooks(from: targets + [duplicate]).count == 30, "identical content in same category appears once")
  var differentCategory = duplicate; differentCategory.categoryTitle = "网络小说"
  precondition(displayStore.displayBooks(from: targets + [differentCategory]).count == 31, "same bytes across categories remain distinct")
  let series = displayStore.series.createSeries(named: "Different series")
  displayStore.series.assign(book: duplicate.key, to: series.id)
  precondition(displayStore.displayBooks(from: targets + [duplicate]).count == 31, "different series remain distinct")
  let cancelledStore = HashStore()
  let cancellationCalls = FileContentHash.calls
  let old = Task { await cancelledStore.refreshHashes(for: targets) }
  while FileContentHash.calls == cancellationCalls { await Task.yield() }
  old.cancel()
  await cancelledStore.refreshHashes(for: [targets[29]])
  await old.value
  precondition(cancelledStore.hashByBook.count == 1 && cancelledStore.hashByBook[targets[29].key] != nil)
  precondition(cancelledStore.publications == 1, "cancelled batch cannot overwrite latest library")
  await cancelledStore.refreshHashes(for: [])
  precondition(cancelledStore.hashByBook.isEmpty && cancelledStore.hashes.isEmpty, "empty library clears stale hashes")
  let forgetting = HashStore()
  let kept = forgetting.series.createSeries(named: "Kept")
  forgetting.series.assign(book: "wenku:gone", to: kept.id)
  forgetting.series.assign(book: "wenku:stay", to: kept.id)
  forgetting.lastOpened = ["wenku:gone": Date(), "wenku:stay": Date()]
  forgetting.forget(keys: ["wenku:gone", "wenku:never-seen"])
  precondition(forgetting.series.seriesID(forBook: "wenku:gone") == nil && forgetting.series.seriesID(forBook: "wenku:stay") == kept.id)
  precondition(forgetting.series.memberships["wenku:gone"] != nil, "removal is recorded so sync propagates it")
  precondition(forgetting.series.memberships["wenku:never-seen"] == nil, "unknown books add no records")
  precondition(Set(forgetting.lastOpened.keys) == ["wenku:stay"] && forgetting.lastOpenedWrites == 1)
  forgetting.forget(keys: ["wenku:gone"])
  precondition(forgetting.lastOpenedWrites == 1, "nothing to forget writes nothing")
  print("Library display grouping, forget-after-delete and background hash/cache/cancellation regressions passed")
 }
}
'''
# Throwing expressions cannot be evaluated inside Swift's precondition autoclosure.
fixture = fixture.replace('precondition(try fm.contentsOfDirectory(atPath: directory.path) == before)', 'let files = try fm.contentsOfDirectory(atPath: directory.path); precondition(files == before)', 1)
fixture = fixture.replace('precondition(try fm.contentsOfDirectory(atPath: directory.path) == before)', 'let afterRollback = try fm.contentsOfDirectory(atPath: directory.path); precondition(afterRollback == before)', 1)
with tempfile.TemporaryDirectory(prefix='NoveliaLibraryStoreRegression-') as temporary:
 path = Path(temporary)
 (path / 'Checks.swift').write_text(fixture)
 subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path/'cache'), str(path/'Checks.swift'), '-o', str(path/'checks')], check=True)
 subprocess.run([str(path/'checks')], check=True)
