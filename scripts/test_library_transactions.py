#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile shipped library stores with platform adapters; use only temporary synthetic data.

Persistence, model decoding, file I/O and mover coordination are production code.
UIKit image conversion, EPUB metadata and remote downloads are local test adapters.
--benchmark records host microbenchmarks, never physical-device qualification.
"""
from pathlib import Path
import argparse
import json
import hashlib
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--benchmark', action='store_true')
parser.add_argument('--output', type=Path)
parser.add_argument('--baseline-ref', help='Explicit pre-transaction commit to compare in isolated temporary directories')
args = parser.parse_args()
parts = [
 'Sources/NoveliaIOSCore/Domain/Novel.swift',
 'Sources/NoveliaIOSCore/Domain/LocalBookRecords.swift',
 'Sources/NoveliaIOSCore/Features/Library/LibraryOrganizer.swift',
 'Sources/NoveliaIOSCore/Support/FileContentHash.swift',
 'Sources/NoveliaIOSCore/Support/DiagnosticContext.swift',
 'Sources/NoveliaIOSCore/Support/SerialAsyncGate.swift',
 'Sources/NoveliaIOSCore/Features/Library/LocalLibraryIndexWriter.swift',
 'iOSApp/Features/Library/WenkuLocalLibraryStore.swift',
 'iOSApp/Features/Downloads/WebNovelDownloadStore.swift',
]
code = '\n'.join((ROOT / name).read_text().replace('import UIKit\n', '') for name in parts)
mover = (ROOT / 'iOSApp/Features/Downloads/DownloadsViews.swift').read_text()
code += '\n' + mover[mover.index('@MainActor\nenum LibraryMover'):mover.index('private let epubImportLog')]
code += '\n' + mover[mover.index('private enum LibraryMoveError:'):]
baseline_commit = None
if args.baseline_ref:
    if not args.benchmark:
        parser.error('--baseline-ref requires --benchmark')
    baseline_commit = subprocess.check_output(['git','rev-parse',args.baseline_ref],cwd=ROOT,text=True).strip()
    previous = subprocess.check_output(['git','show',baseline_commit+':iOSApp/Features/Library/WenkuLocalLibraryStore.swift'],cwd=ROOT,text=True)
    previous = previous.replace('import UIKit\n','').replace('WenkuLocalLibraryStore','BaselineWenkuLocalLibraryStore')
    previous = previous.replace('LocalLibraryDuplicateError','BaselineLocalLibraryDuplicateError').replace('WenkuLocalLibraryError','BaselineWenkuLocalLibraryError')
    expected = 'init(fileManager: FileManager = .default) {'
    if expected not in previous:
        parser.error('Baseline must be the older synchronous-index Store')
    previous = previous.replace(expected,'init(fileManager: FileManager = .default, benchmarkDirectory: URL) {')
    previous = previous.replace('directory = applicationSupport.appendingPathComponent("WenkuEPUB", isDirectory: true)','directory = benchmarkDirectory')
    code += '\n' + previous

code += r'''
final class UIImage: @unchecked Sendable {
 func jpegData(compressionQuality: Double) -> Data? {
  precondition(!Thread.isMainThread, "cover encoding must leave the main thread")
  return Data("synthetic cover".utf8)
 }
}
enum EPUBContainer {
 struct Metadata { var title: String?; var description: String?; var authors: [String]; var cover: UIImage? }
 static func metadata(fileURL: URL, coverMaxSize: CGSize) async -> Metadata? { nil }
}
enum TXTLoadSource { case download, `import` }
actor TXTBookCache {
 static let shared = TXTBookCache()
 func contentHash(of url: URL) throws -> String { try FileContentHash.sha256(url) }
 func validateDecodable(at url: URL, source: TXTLoadSource, trace: String) throws -> String { try contentHash(of: url) }
}
protocol NovelDownloadService {
 func downloadWebNovelEPUB(to: URL, providerId: String, novelId: String, title: String,
                          translationSource: NovelTranslationSource?, mode: WebNovelDownloadMode) async throws
}
struct FakeAPI: NovelDownloadService {
 func downloadWebNovelEPUB(to: URL, providerId: String, novelId: String, title: String,
                          translationSource: NovelTranslationSource?, mode: WebNovelDownloadMode) async throws {
  try Data("PKsynthetic".utf8).write(to: to)
 }
}
@MainActor final class LibraryStateStore {
 var transfers: [(String, String)] = []
 func transfer(from: String, to: String) { transfers.append((from, to)) }
}
final class Faults: @unchecked Sendable {
 let lock = NSLock()
 var failWrites: Set<Int> = []
 var writes = 0
 var pauseOnWrite: Int?
 let entered = DispatchSemaphore(value: 0)
 let resume = DispatchSemaphore(value: 0)
 func persist(_ data: Data, _ url: URL) throws {
  precondition(!Thread.isMainThread, "index write must leave the main thread")
  lock.lock(); writes += 1; let current = writes
  let fail = failWrites.contains(current); let pause = pauseOnWrite == current; lock.unlock()
  if pause { entered.signal(); resume.wait() }
  if fail { throw CocoaError(.fileWriteOutOfSpace) }
  try data.write(to: url, options: .atomic)
 }
}
@MainActor func waitUntil(_ predicate: () -> Bool) async throws {
 for _ in 0..<10000 {
  if predicate() { return }
  try await Task.sleep(nanoseconds: 1_000_000)
 }
 throw CocoaError(.fileReadUnknown)
}
@MainActor func waitEntered(_ signal: DispatchSemaphore) async throws {
 try await waitUntil { signal.wait(timeout: .now()) == .success }
}
func createBook(_ directory: URL, title: String = "Old", count: Int = 1) throws -> [LocalWenkuEPUB] {
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 let file = directory.appendingPathComponent("book.txt")
 try Data("第一章 起点\n正文\n第二章 后续\n内容".utf8).write(to: file)
 let records = (0..<count).map { LocalWenkuEPUB(id: UUID(), title: "\(title) \($0)", filename: "book.txt",
                       addedAt: Date(timeIntervalSince1970: Double($0)), metadataLoaded: true, fileFormat: .txt) }
 try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("library.json"))
 return records
}
func disk(_ directory: URL) throws -> [LocalWenkuEPUB] {
 try JSONDecoder().decode([LocalWenkuEPUB].self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
}
@main struct Checks {
 @MainActor static func main() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("NoveliaTransactions-\(UUID())")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  if CommandLine.arguments.contains("--benchmark") { try await benchmark(root); return }
  // Legacy optional fields remain decodable; initialization does no eager index I/O.
  let legacyDir = root.appendingPathComponent("legacy")
  let old = try createBook(legacyDir)[0]
  let index = legacyDir.appendingPathComponent("library.json")
  var json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [[String: Any]]
  for key in ["metadataUpdatedAt", "fileFormat", "metadataLoaded", "sourceWebNovel", "lastLocatorJSON"] { json[0].removeValue(forKey: key) }
  try JSONSerialization.data(withJSONObject: json).write(to: index)
  let legacy = WenkuLocalLibraryStore(directory: legacyDir)
  precondition(legacy.books.isEmpty && legacy.isLoading && !legacy.isReady)
  try await legacy.loadIfNeeded()
  precondition(legacy.books.count == 1 && legacy.books[0].id == old.id && legacy.books[0].resolvedFileFormat == .txt)
  // Download records from before format/mode fields were introduced remain readable.
  let webLegacyDir = root.appendingPathComponent("legacy-web")
  try fm.createDirectory(at: webLegacyDir, withIntermediateDirectories: true)
  try Data("legacy text".utf8).write(to: webLegacyDir.appendingPathComponent("legacy.txt"))
  let legacyNovel = Novel(id: "legacy", title: "Legacy", author: "", summary: "", genres: [], chapters: [], accent: .plum)
  let legacyWeb = DownloadedWebNovel(novel: legacyNovel, fileFilename: "legacy.txt", downloadedAt: Date(),
                                    translationSource: nil, downloadMode: nil, fileFormat: nil)
  try JSONEncoder().encode([legacyWeb]).write(to: webLegacyDir.appendingPathComponent("library.json"))
  let webLegacy = WebNovelDownloadStore(api: FakeAPI(), directory: webLegacyDir)
  try await webLegacy.loadIfNeeded()
  precondition(webLegacy.books.first?.resolvedFileFormat == .txt && webLegacy.books.first?.resolvedDownloadMode == .original)
  // A corrupt index cannot silently become an empty library and be overwritten.
  let corruptDir = root.appendingPathComponent("corrupt")
  try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
  let corruptURL = corruptDir.appendingPathComponent("library.json")
  let damaged = Data("broken index".utf8); try damaged.write(to: corruptURL)
  let corrupt = WenkuLocalLibraryStore(directory: corruptDir)
  do { try await corrupt.loadIfNeeded(); preconditionFailure("must reject damaged index") } catch {}
  precondition(corrupt.storageError != nil && !corrupt.isLoading && !corrupt.isReady)
  let keptCorrupt = try Data(contentsOf: corruptURL); precondition(keptCorrupt == damaged)
  _ = try createBook(corruptDir)
  try await corrupt.loadIfNeeded(); precondition(corrupt.books.count == 1 && corrupt.storageError == nil && corrupt.isReady)
  // Failed edits/deletes do not publish or remove files; retry persists successfully.
  let editDir = root.appendingPathComponent("edit"); let original = try createBook(editDir)[0]
  let faults = Faults(); faults.failWrites = [1, 2]
  let edits = WenkuLocalLibraryStore(directory: editDir, indexWriter: LocalLibraryIndexWriter(persist: { try faults.persist($0, $1) }))
  try await edits.loadIfNeeded()
  do { try await edits.updateMetadata(id: original.id, title: "New", author: nil, description: nil, cover: .replace(UIImage())); preconditionFailure("must fail edit") } catch {}
  precondition(edits.books == [original]); let savedBefore = try disk(editDir); precondition(savedBefore == [original])
  precondition(!(try fm.contentsOfDirectory(atPath: editDir.path)).contains { $0.hasPrefix("cover-") })
  do { try await edits.remove(original); preconditionFailure("must fail delete") } catch {}
  precondition(edits.books == [original] && fm.fileExists(atPath: edits.fileURL(for: original).path))
  try await edits.remove(original); precondition(edits.books.isEmpty)
  precondition(!fm.fileExists(atPath: edits.fileURL(for: original).path))
  // 网络封面下载后才调用实际 Store：旧快照不能覆盖更晚的本机编辑，时间相同也保留本机。
  let syncEditDir = root.appendingPathComponent("sync-metadata")
  let syncOriginal = try createBook(syncEditDir)[0]
  let syncEdits = WenkuLocalLibraryStore(directory: syncEditDir)
  try await syncEdits.loadIfNeeded()
  var remoteSnapshot = syncOriginal
  remoteSnapshot.title = "Old remote snapshot"
  remoteSnapshot.metadataUpdatedAt = Date(timeIntervalSince1970: 100)
  try await syncEdits.updateMetadata(id: syncOriginal.id, title: "New local edit", author: "Local author", description: "Local description", cover: .replace(UIImage()))
  let newLocal = syncEdits.books[0]
  let newCover = syncEdits.coverFileURL(for: newLocal)!
  let coverBytes = try Data(contentsOf: newCover)
  precondition(newLocal.metadataUpdatedAt! > remoteSnapshot.metadataUpdatedAt!)
  try await syncEdits.applySyncedMetadata(remoteSnapshot, cover: nil)
  precondition(syncEdits.books == [newLocal])
  remoteSnapshot.metadataUpdatedAt = newLocal.metadataUpdatedAt
  try await syncEdits.applySyncedMetadata(remoteSnapshot, cover: nil)
  precondition(syncEdits.books == [newLocal])
  let persistedLocal = try disk(syncEditDir)
  let preservedCover = try Data(contentsOf: newCover)
  precondition(persistedLocal == [newLocal] && preservedCover == coverBytes)
  // 即使修改时间更晚，也不能跨文件版本套用信息；正常的同版本较新信息仍可落盘。
  let wrongVersion = LocalWenkuEPUB(id: syncOriginal.id, title: "Wrong file version", filename: syncOriginal.filename,
                              addedAt: syncOriginal.addedAt.addingTimeInterval(1), metadataUpdatedAt: Date.distantFuture)
  try await syncEdits.applySyncedMetadata(wrongVersion, cover: nil)
  precondition(syncEdits.books == [newLocal])
  remoteSnapshot.metadataUpdatedAt = newLocal.metadataUpdatedAt!.addingTimeInterval(10)
  remoteSnapshot.title = "Valid newer remote edit"
  try await syncEdits.applySyncedMetadata(remoteSnapshot, cover: nil)
  precondition(syncEdits.books[0].title == remoteSnapshot.title && syncEdits.books[0].coverFilename == nil)
  let persistedRemote = try disk(syncEditDir)
  precondition(persistedRemote == syncEdits.books && !fm.fileExists(atPath: newCover.path))
  // Background metadata failures remain retryable and do not leave a stale error after success.
  let metadataDir = root.appendingPathComponent("metadata")
  var incomplete = try createBook(metadataDir)[0]; incomplete.metadataLoaded = nil
  try JSONEncoder().encode([incomplete]).write(to: metadataDir.appendingPathComponent("library.json"))
  let metadataFault = Faults(); metadataFault.failWrites = [1]
  let metadataStore = WenkuLocalLibraryStore(directory: metadataDir,
      indexWriter: LocalLibraryIndexWriter(persist: { try metadataFault.persist($0, $1) }))
  await metadataStore.refreshMissingMetadata()
  precondition(metadataStore.storageError != nil && metadataStore.books == [incomplete])
  await metadataStore.refreshMissingMetadata()
  precondition(metadataStore.storageError == nil && metadataStore.books.first?.metadataLoaded == true)
  // Simultaneous imports of identical bytes keep exactly one copy and do not delete it.
  let duplicateDir = root.appendingPathComponent("duplicates")
  let duplicateStore = WenkuLocalLibraryStore(directory: duplicateDir)
  try await duplicateStore.loadIfNeeded()
  let one = duplicateDir.appendingPathComponent("one.txt"), two = duplicateDir.appendingPathComponent("two.txt")
  try Data("same text".utf8).write(to: one); try Data("same text".utf8).write(to: two)
  let firstImport = Task { () async throws -> Bool in
   do { try await duplicateStore.registerDownloadedFile(at: one, title: "One"); return true }
   catch is LocalLibraryDuplicateError { return false }
  }
  let secondImport = Task { () async throws -> Bool in
   do { try await duplicateStore.registerDownloadedFile(at: two, title: "Two"); return true }
   catch is LocalLibraryDuplicateError { return false }
  }
  let importResults = try await [firstImport.value, secondImport.value]
  precondition(importResults.filter { $0 }.count == 1 && duplicateStore.books.count == 1)
  precondition(fm.fileExists(atPath: duplicateStore.fileURL(for: duplicateStore.books[0]).path))
  // A source commit failure rolls back the destination; the original remains readable.
  let sourceDir = root.appendingPathComponent("source"); let sourceBook = try createBook(sourceDir)[0]
  let sourceFaults = Faults(); sourceFaults.failWrites = [1]
  let source = WenkuLocalLibraryStore(directory: sourceDir, indexWriter: LocalLibraryIndexWriter(persist: { try sourceFaults.persist($0, $1) }))
  let targetDir = root.appendingPathComponent("target")
  let target = WebNovelDownloadStore(api: FakeAPI(), directory: targetDir)
  let state = LibraryStateStore()
  try await source.loadIfNeeded(); try await target.loadIfNeeded()
  do { try await LibraryMover.moveToNetwork(sourceBook, web: target, wenku: source, state: state); preconditionFailure("source commit must fail") } catch {}
  precondition(source.books == [sourceBook] && target.books.isEmpty && state.transfers.isEmpty)
  precondition(fm.fileExists(atPath: source.fileURL(for: sourceBook).path))
  try await LibraryMover.moveToNetwork(sourceBook, web: target, wenku: source, state: state)
  precondition(source.books.isEmpty && target.books.count == 1 && state.transfers.count == 1)
  let existingTarget = target.books[0]
  let targetFilesBefore = try fm.contentsOfDirectory(atPath: targetDir.path).sorted()
  do {
   _ = try await target.importForMove(from: target.fileURL(for: existingTarget), book: sourceBook)
   preconditionFailure("duplicate target identity must be rejected")
  } catch WebNovelMoveError.alreadyExists {}
  let targetFilesAfter = try fm.contentsOfDirectory(atPath: targetDir.path).sorted()
  precondition(target.books == [existingTarget] && targetFilesBefore == targetFilesAfter)
  // Destination rollback failure is explicit; neither source data nor progress is discarded.
  let rollbackDir = root.appendingPathComponent("rollback-source"); let rollbackBook = try createBook(rollbackDir)[0]
  let sourceFail = Faults(); sourceFail.failWrites = [1]
  let targetFail = Faults(); targetFail.failWrites = [2]
  let rs = WenkuLocalLibraryStore(directory: rollbackDir, indexWriter: LocalLibraryIndexWriter(persist: { try sourceFail.persist($0, $1) }))
  let rt = WebNovelDownloadStore(api: FakeAPI(), directory: root.appendingPathComponent("rollback-target"), indexWriter: LocalLibraryIndexWriter(persist: { try targetFail.persist($0, $1) }))
  let rstate = LibraryStateStore()
  do { try await LibraryMover.moveToNetwork(rollbackBook, web: rt, wenku: rs, state: rstate); preconditionFailure("must surface rollback failure") }
  catch { precondition(error.localizedDescription.contains("副本清理失败")) }
  precondition(rs.books.count == 1 && rt.books.count == 1 && rstate.transfers.isEmpty)
  // If the destination was edited while source deletion failed, rollback must preserve that edit and report the duplicate explicitly.
  let protectedSourceDir = root.appendingPathComponent("protected-web")
  try fm.createDirectory(at: protectedSourceDir, withIntermediateDirectories: true)
  try Data("original".utf8).write(to: protectedSourceDir.appendingPathComponent(legacyWeb.fileFilename))
  try JSONEncoder().encode([legacyWeb]).write(to: protectedSourceDir.appendingPathComponent("library.json"))
  let protectedFault = Faults(); protectedFault.failWrites = [1]; protectedFault.pauseOnWrite = 1
  let protectedSource = WebNovelDownloadStore(api: FakeAPI(), directory: protectedSourceDir,
      indexWriter: LocalLibraryIndexWriter(persist: { try protectedFault.persist($0, $1) }))
  let protectedTarget = WenkuLocalLibraryStore(directory: root.appendingPathComponent("protected-wenku"))
  let protectedState = LibraryStateStore()
  let protectedMove = Task { try await LibraryMover.moveToWenku(legacyWeb, web: protectedSource, wenku: protectedTarget, state: protectedState) }
  try await waitEntered(protectedFault.entered)
  let createdTarget = protectedTarget.books[0]
  try await protectedTarget.updateMetadata(id: createdTarget.id, title: "Edited destination", author: nil, description: nil, cover: .keep)
  protectedFault.resume.signal()
  do { try await protectedMove.value; preconditionFailure("must preserve a modified destination") }
  catch { precondition(error.localizedDescription.contains("副本清理失败")) }
  precondition(protectedSource.books == [legacyWeb] && protectedTarget.books.first?.title == "Edited destination" && protectedState.transfers.isEmpty)
  // During an in-flight index write the old visible snapshot remains; a following insert uses the committed edit.
  let concurrentDir = root.appendingPathComponent("concurrent"); let base = try createBook(concurrentDir)[0]
  let delayed = Faults(); delayed.pauseOnWrite = 1
  let concurrent = WenkuLocalLibraryStore(directory: concurrentDir, indexWriter: LocalLibraryIndexWriter(persist: { try delayed.persist($0, $1) }))
  try await concurrent.loadIfNeeded()
  let edit = Task { try await concurrent.updateMetadata(id: base.id, title: "Edited", author: "Author", description: nil, cover: .keep) }
  try await waitEntered(delayed.entered)
  precondition(concurrent.books[0].title == base.title, "no optimistic publication before disk commit")
  let incoming = LocalWenkuEPUB(id: UUID(), title: "Incoming", filename: "incoming.txt", addedAt: Date(), metadataLoaded: true, fileFormat: .txt)
  let incomingFile = root.appendingPathComponent("incoming.txt"); try Data("new content".utf8).write(to: incomingFile)
  let insert = Task { try await concurrent.restoreFromSync(incoming, files: [incoming.filename: incomingFile]) }
  delayed.resume.signal(); try await edit.value; try await insert.value
  precondition(concurrent.books.count == 2 && concurrent.books.contains { $0.title == "Edited" })
  let savedConcurrent = try disk(concurrentDir); precondition(savedConcurrent == concurrent.books)
  // Cancellation after a destination write has started still publishes committed state, then rolls it back in an uncancelled cleanup task.
  let cancelDir = root.appendingPathComponent("cancel-source"); let cancelBook = try createBook(cancelDir)[0]
  let cs = WenkuLocalLibraryStore(directory: cancelDir)
  let paused = Faults(); paused.pauseOnWrite = 1
  let ct = WebNovelDownloadStore(api: FakeAPI(), directory: root.appendingPathComponent("cancel-target"), indexWriter: LocalLibraryIndexWriter(persist: { try paused.persist($0, $1) }))
  let cancelState = LibraryStateStore()
  let moving = Task { try await LibraryMover.moveToNetwork(cancelBook, web: ct, wenku: cs, state: cancelState) }
  try await waitEntered(paused.entered); moving.cancel(); paused.resume.signal()
  do { try await moving.value; preconditionFailure("cancelled move must fail") } catch {}
  precondition(cs.books.count == 1 && ct.books.isEmpty && cancelState.transfers.isEmpty)
  precondition(fm.fileExists(atPath: cs.fileURL(for: cancelBook).path))
  // A replacement copy completing after deletion cannot resurrect the old book.
  let raceDir = root.appendingPathComponent("race"); let raceBook = try createBook(raceDir)[0]
  let copyEntered = DispatchSemaphore(value: 0); let copyResume = DispatchSemaphore(value: 0)
  let copier = LocalLibraryFileCopier { input, output in
   copyEntered.signal(); copyResume.wait(); try FileManager.default.copyItem(at: input, to: output)
  }
  let race = WenkuLocalLibraryStore(directory: raceDir, fileCopier: copier)
  try await race.loadIfNeeded()
  let replacement = Task { try await race.replaceFromSync(raceBook, files: [raceBook.filename: incomingFile]) }
  try await waitEntered(copyEntered)
  let removing = Task { try await race.remove(raceBook) }
  try await waitUntil { race.books.isEmpty }; copyResume.signal()
  try await removing.value
  do { try await replacement.value; preconditionFailure("deleted book must not be restored by an old copy") } catch {}
  precondition(race.books.isEmpty)
  let raceNames = try fm.contentsOfDirectory(atPath: raceDir.path)
  precondition(!raceNames.contains { $0.hasPrefix("sync-") || $0.hasPrefix(".copy-") })
  print("Library transactions passed: legacy load, corrupt-index recovery, failed edit/delete, stale/equal/wrong-version synced metadata, newer remote metadata persistence, move rollback and rollback failure, in-flight commit, cancellation and copy/delete race")
 }
 @MainActor static func responsiveness(_ root: URL, synchronous: Bool) async throws -> [String: Double] {
  var maxGap = 0.0
  let ticker = Task { @MainActor in
   var last = ProcessInfo.processInfo.systemUptime
   while !Task.isCancelled {
    do { try await Task.sleep(nanoseconds: 1_000_000) } catch { break }
    let now = ProcessInfo.processInfo.systemUptime
    maxGap = max(maxGap, (now-last)*1000); last = now
   }
  }
  let writer = LocalLibraryIndexWriter { data, url in
   Thread.sleep(forTimeInterval: 0.08)
   try data.write(to: url, options: .atomic)
  }
  try await Task.sleep(nanoseconds: 10_000_000)
  let start = ProcessInfo.processInfo.systemUptime
  let url = root.appendingPathComponent("responsiveness-\(synchronous).json")
  if synchronous { try writer.writeSync(["sample"], to: url) }
  else { try await writer.write(["sample"], to: url) }
  let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
  try await Task.sleep(nanoseconds: 10_000_000)
  ticker.cancel(); await ticker.value
  return ["operation_ms": elapsed, "max_main_actor_gap_ms": maxGap]
 }
 @MainActor static func benchmark(_ root: URL) async throws {
  var results: [[String: Any]] = []
  for count in [0, 300, 3000] {
   var load: [Double] = []; var edit: [Double] = []
   var baselineLoad: [Double] = []; var baselineEdit: [Double] = []
   for sample in 0..<5 {
    // BASELINE_BENCHMARK
    let directory = root.appendingPathComponent("bench-\(count)-\(sample)")
    _ = try createBook(directory, count: count)
    let store = WenkuLocalLibraryStore(directory: directory)
    let start = ProcessInfo.processInfo.systemUptime; try await store.loadIfNeeded()
    load.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    if let book = store.books.first {
     let start = ProcessInfo.processInfo.systemUptime
     try await store.updateMetadata(id: book.id, title: "Edited", author: nil, description: nil, cover: .keep)
     edit.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    }
   }
   results.append(["books": count, "load_ms": load, "edit_commit_ms": edit,
                   "baseline_load_ms": baselineLoad, "baseline_edit_ms": baselineEdit])
  }
  let file = root.appendingPathComponent("large.txt")
  try Data(repeating: 65, count: 9*1024*1024).write(to: file)
  var copying: [Double] = []
  for sample in 0..<5 {
   let start = ProcessInfo.processInfo.systemUptime
   try await LocalLibraryFileCopier().copy(from: file, to: root.appendingPathComponent("copied-\(sample).txt"))
   copying.append((ProcessInfo.processInfo.systemUptime-start)*1000)
  }
  let blocking = try await responsiveness(root, synchronous: true)
  let background = try await responsiveness(root, synchronous: false)
  let object: [String: Any] = ["scope": "host_microbenchmark", "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "configuration": "swiftc -O; synthetic library, platform image/metadata adapters", "samples": 5, "cache": "warm filesystem cache", "baseline_commit": "BASELINE_COMMIT",
      "library": results, "copy_9_mib_ms": copying,
      "controlled_io_stress": ["injected_delay_ms": 80, "synchronous": blocking, "background": background],
      "limitations": ["not physical iOS device", "filesystem copy may use cloning/caching, not storage throughput", "not EPUB layout or TXT parsing", "does not qualify CPU, battery, peak memory or real server sync"]]
  let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
 }
}
'''
code += r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
 if !condition() { fatalError("Regression failed at generated line \(line): \(message)") }
}
'''
code = code.replace('precondition(', 'require(')
if baseline_commit:
    code = code.replace('// BASELINE_BENCHMARK', r'''
    let baselineDirectory = root.appendingPathComponent("baseline-\(count)-\(sample)")
    _ = try createBook(baselineDirectory, count: count)
    let baselineStart = ProcessInfo.processInfo.systemUptime
    let baseline = BaselineWenkuLocalLibraryStore(benchmarkDirectory: baselineDirectory)
    baselineLoad.append((ProcessInfo.processInfo.systemUptime-baselineStart)*1000)
    if let book = baseline.books.first {
     let start = ProcessInfo.processInfo.systemUptime
     try baseline.updateMetadata(id: book.id, title: "Edited", author: nil, description: nil, cover: .keep)
     baselineEdit.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    }
''').replace('BASELINE_COMMIT', baseline_commit)
else:
    code = code.replace('BASELINE_COMMIT', 'none').replace('var baselineLoad: [Double] = []; var baselineEdit: [Double] = []', 'let baselineLoad: [Double] = []; let baselineEdit: [Double] = []')
# Swift assertion autoclosures cannot contain throwing operations.
code = code.replace('require(!(try fm.contentsOfDirectory(atPath: editDir.path)).contains { $0.hasPrefix("cover-") })',
                    'let editFiles = try fm.contentsOfDirectory(atPath: editDir.path); require(!editFiles.contains { $0.hasPrefix("cover-") })')
with tempfile.TemporaryDirectory(prefix='NoveliaLibraryTransactions-') as temporary:
    work = Path(temporary)
    (work/'Checks.swift').write_text(code)
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(work/'cache'),str(work/'Checks.swift'),'-o',str(work/'checks')],check=True)
    result = subprocess.run([str(work/'checks')] + (['--benchmark'] if args.benchmark else []),capture_output=True,text=True)
    if result.returncode:
        diagnostic = Path(tempfile.gettempdir())/'novelia-library-transactions-failed.swift'
        diagnostic.write_text(code)
        print(result.stderr[:6000], file=sys.stderr)
        raise SystemExit(f'Transaction regression failed; generated source: {diagnostic}')
    if args.benchmark:
        report = json.loads(result.stdout)
        report['generated_source_sha256'] = hashlib.sha256(code.encode()).hexdigest()
        report['swift_version'] = subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip()
        result.stdout = json.dumps(report,ensure_ascii=False,indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(result.stdout)
    print(result.stdout, end='')
