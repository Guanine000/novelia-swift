#!/usr/bin/env python3
"""Exercise production move/hash methods with isolated files; never touches a user's library."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'iOSApp/Features/Library/WenkuLocalLibraryStore.swift').read_text() + (root / 'iOSApp/Features/Downloads/WebNovelDownloadStore.swift').read_text()
move = source[source.index('    func importForMove(from source: URL, book: LocalWenkuEPUB)'):source.index('    func removeForMove', source.index('    func importForMove(from source: URL, book: LocalWenkuEPUB)'))]
error = source[source.index('private enum WebNovelMoveError:'):]
registration = source[source.index('    func registerDownloadedFile('):source.index('    func importForMove(from source: URL, sourceBook:')]
existing = source[source.index('    private func existingBook('):source.index('    func registerDownloadedFile(')]
local_error = source[source.index('struct LocalLibraryDuplicateError:'):source.index('struct WebNovelDownloadProgress:')]
source = (root / 'iOSApp/Features/Library/LibraryStore.swift').read_text()
display = source[source.index('    func displayBooks'):source.index('    func status(for')]
identity = source[source.index('    nonisolated private static func identity'):source.index('    private func hash(for')]
refresh = source[source.index('    func refreshHashes'):source.index('    // MARK: 排序设置')]
forget = source[source.index('    func forget(keys:'):source.index('    /// WebDAV 合并后的系列状态。')]
fixture = r'''
import Foundation
struct Novel { var id: String; var title: String; var author: String; var summary: String; var genres: [String]; var chapters: [String]; var accent: Accent }
enum Accent { case plum }
enum Format { case txt, epub }
struct DownloadedWebNovel { var novel: Novel; var fileFilename: String; var downloadedAt: Date; var translationSource: String?; var downloadMode: String?; var fileFormat: Format?; var id: String { novel.id } }
struct LocalWenkuEPUB { var id = UUID(); var title = "Test"; var author: String?; var bookDescription: String?; var sourceWebNovel: DownloadedWebNovel?; var addedAt = Date(); var resolvedFileFormat = Format.epub }
final class MoveStore {
 var books: [DownloadedWebNovel] = []; let fileManager = FileManager.default; let directory: URL; var failPersist = false
 init(_ directory: URL) { self.directory = directory }
 func uniqueDestination(for name: String) -> URL { directory.appendingPathComponent(UUID().uuidString + name) }
 func persistIndex() throws { if failPersist { throw CocoaError(.fileWriteUnknown) } }
'''
fixture += move + '\n}\n' + error
fixture += r'''
typealias WebNovelFileFormat = Format
enum TXTLoadSource { case download, `import` }
enum DiagnosticContext { static func newTraceID() -> String { "test" } }
actor TXTBookCache {
 static let shared = TXTBookCache()
 func contentHash(of url: URL) throws -> String { try Data(contentsOf: url).base64EncodedString() }
 func validateDecodable(at url: URL, source: TXTLoadSource, trace: String) throws -> String { try contentHash(of: url) }
}
struct RegistrationBook {
 let id: UUID; let title: String; let filename: String; let addedAt: Date
 var bookDescription: String?; var author: String?; var coverFilename: String?; var metadataLoaded: Bool?; var fileFormat: Format?
 var resolvedFileFormat: Format { fileFormat ?? .epub }
 init(id: UUID, title: String, filename: String, addedAt: Date, bookDescription: String? = nil, author: String? = nil, coverFilename: String? = nil, metadataLoaded: Bool? = nil, fileFormat: Format? = nil) {
  self.id = id; self.title = title; self.filename = filename; self.addedAt = addedAt; self.bookDescription = bookDescription; self.author = author; self.coverFilename = coverFilename; self.metadataLoaded = metadataLoaded; self.fileFormat = fileFormat
 }
}
@MainActor final class RegistrationStore {
 let directory: URL; let fileManager = FileManager.default; var books: [RegistrationBook] = []
 init(_ directory: URL) { self.directory = directory }
 func persistIndex() throws {}
 static func metadata(for url: URL) async -> (title: String?, description: String?, author: String?, cover: Data?) { ("EPUB Title", nil, nil, nil) }
 func saveCover(_ cover: Data?, id: UUID) throws -> String? { nil }
 nonisolated static func fileSize(_ url: URL) -> Int? { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }
'''
fixture += existing.replace('LocalWenkuEPUB', 'RegistrationBook') + registration.replace('LocalWenkuEPUB', 'RegistrationBook') + '\n}\n' + local_error

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
  let input = directory.appendingPathComponent("input.epub")
  try Data("source remains intact".utf8).write(to: input)
  let novel = Novel(id: "same-work", title: "Same", author: "Author", summary: "", genres: [], chapters: [], accent: .plum)
  let existing = DownloadedWebNovel(novel: novel, fileFilename: "existing.epub", downloadedAt: Date(), translationSource: nil, downloadMode: nil, fileFormat: .epub)
  let local = LocalWenkuEPUB(sourceWebNovel: existing)
  let store = MoveStore(directory)
  store.books = [existing]
  let before = try fm.contentsOfDirectory(atPath: directory.path)
  do { _ = try store.importForMove(from: input, book: local); preconditionFailure("duplicate move must fail") }
  catch WebNovelMoveError.alreadyExists { }
  precondition(store.books.count == 1 && store.books[0].fileFilename == existing.fileFilename)
  precondition(try fm.contentsOfDirectory(atPath: directory.path) == before)
  precondition(fm.fileExists(atPath: input.path))
  store.books = []; store.failPersist = true
  do { _ = try store.importForMove(from: input, book: local); preconditionFailure("failed persistence must roll back") }
  catch { }
  precondition(store.books.isEmpty)
  precondition(try fm.contentsOfDirectory(atPath: directory.path) == before)
  store.failPersist = false
  _ = try store.importForMove(from: input, book: local)
  precondition(store.books.count == 1)
  let registration = RegistrationStore(directory)
  let firstEPUB = directory.appendingPathComponent("first.epub")
  let duplicateEPUB = directory.appendingPathComponent("duplicate.epub")
  let differentEPUB = directory.appendingPathComponent("different.epub")
  try Data("PKsame EPUB bytes".utf8).write(to: firstEPUB)
  try Data("PKsame EPUB bytes".utf8).write(to: duplicateEPUB)
  try Data("PKdifferent EPUB bytes".utf8).write(to: differentEPUB)
  try await registration.registerDownloadedFile(at: firstEPUB, title: "Title")
  do { try await registration.registerDownloadedFile(at: firstEPUB, title: "Repeated callback"); preconditionFailure("same file cannot be registered twice") }
  catch is LocalLibraryDuplicateError {}
  precondition(registration.books.count == 1 && fm.fileExists(atPath: firstEPUB.path))
  do { try await registration.registerDownloadedFile(at: duplicateEPUB, title: "Same title"); preconditionFailure("duplicate EPUB must fail") }
  catch is LocalLibraryDuplicateError {}
  precondition(registration.books.count == 1 && fm.fileExists(atPath: firstEPUB.path))
  precondition(!fm.fileExists(atPath: duplicateEPUB.path), "only incoming duplicate copy is removed")
  try await registration.registerDownloadedFile(at: differentEPUB, title: "Same title")
  precondition(registration.books.count == 2, "same title with different bytes is retained")
  let targets = try (0..<30).map { index in
   let url = directory.appendingPathComponent("hash-\(index).txt")
   try Data("content-\(index)".utf8).write(to: url)
   return LibraryBook(key: "book-\(index)", fileURL: url)
  }
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
  print("Library EPUB duplicates, display grouping, move rollback, forget-after-delete and background hash/cache/cancellation regressions passed")
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
