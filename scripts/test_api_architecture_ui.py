#!/usr/bin/env python3
"""在独立的 App 包中，让真实 RootView 与各功能运行在完整的替代后台上。"""
from pathlib import Path
import argparse
import subprocess
import tempfile
import json
import hashlib
import plistlib
import shutil
import time
import uuid
import zipfile
import struct
import zlib
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--app', required=True, help='Built dedicated architecture-validation Novelia.app')
parser.add_argument('--only-testing', help='Run one UI regression after a targeted change')
parser.add_argument('--performance', action='store_true', help='Record simulator Debug baseline metrics instead of functional UI regressions')
parser.add_argument('--library-count', type=int, choices=[0, 300, 3000], default=300)
parser.add_argument('--iterations', type=int, choices=range(2, 11), default=3)
parser.add_argument('--result-json', type=Path)
parser.add_argument('--epub-failure', choices=['archive', 'chapter', 'spine'], help='Exercise a synthetic broken EPUB in the dedicated App only')
parser.add_argument('--library-delete', action='store_true', help='Verify deletion of collapsed duplicates and nonblocking cloud failure')
parser.add_argument('--epub-pagination', action='store_true', help='Check actual visible paragraph continuity with Readium in a synthetic EPUB')
parser.add_argument('--library-archive', action='store_true', help='Exercise library/series multi-select archive sharing in the dedicated App only')
args = parser.parse_args()
if args.library_delete and (args.library_archive or args.epub_pagination or args.epub_failure or args.performance):
    parser.error('--library-delete must run independently')
if args.epub_pagination and (args.epub_failure or args.performance or args.library_archive):
    parser.error('--epub-pagination must run independently')
if args.epub_failure and args.performance:
    parser.error('--epub-failure cannot be combined with --performance')
if args.library_archive and (args.epub_failure or args.performance):
    parser.error('--library-archive cannot be combined with --epub-failure or --performance')
if plistlib.loads((Path(args.app)/'Info.plist').read_bytes()).get('CFBundleIdentifier') != 'cc.novelia.ios.architecture-validation':
    parser.error('Requires the dedicated architecture-validation App bundle')
r = Path(tempfile.mkdtemp(prefix='NoveliaArchitectureUI-'))
# 只启动所选模拟器；安装的 App 使用独立的包标识与数据。
subprocess.run(['xcrun','simctl','boot',args.device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['xcrun','simctl','bootstatus',args.device,'-b'], check=True)
subprocess.run(['xcrun','simctl','install',args.device,args.app], check=True)
(r/'TapRegression.swift').write_text('import SwiftUI\n@main struct TapRegressionApp: App { var body: some Scene { WindowGroup { Text("Architecture UI runner") } } }\n')
(r/'TapTests.swift').write_text(r'''import XCTest
final class TapTests: XCTestCase {
 let bundle = "cc.novelia.ios.architecture-validation"
 func start(readium: Bool = false, failSearch: Bool = false, txt: Bool = false, webUpdate: Bool = false, ambiguous: Bool = false, large: Bool = false) -> XCUIApplication {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation"]
  if txt { app.launchArguments.append("-architectureTXT") }
  if webUpdate { app.launchArguments.append("-architectureWebEPUBUpdate") }
  if ambiguous { app.launchArguments.append("-architectureWebEPUBAmbiguous") }
  if large { app.launchArguments.append("-architectureLargeWebEPUB") }
  if failSearch { app.launchArguments.append("-architectureFailFirstSearch") }
  if readium { app.launchArguments.append("-architectureReadium") }
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 15))
  return app
 }
 func reveal(_ element: XCUIElement, app: XCUIApplication, up: Bool = true) {
  for _ in 0..<8 {
   if element.exists && element.isHittable { return }
   if up { app.swipeUp() } else { app.swipeDown() }
  }
  XCTAssertTrue(element.exists && element.isHittable, "Control is not reachable: \(element)")
 }
 func zeroExternalRequests(_ app: XCUIApplication) {
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("\u{5916}\u{90e8}\u{8bf7}\u{6c42} 0"))
 }
 func openNovel(_ app: XCUIApplication) {
  app.tabBars.buttons["\u{53d1}\u{73b0}"].tap()
  let book = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
  XCTAssertTrue(app.navigationBars["\u{4f5c}\u{54c1}\u{8be6}\u{60c5}"].waitForExistence(timeout: 10))
 }

 func revealInfo(_ element: XCUIElement, app: XCUIApplication, up: Bool = true) {
  for _ in 0..<10 {
   if element.exists { return }
   if up { app.swipeUp() } else { app.swipeDown() }
  }
  XCTAssertTrue(element.exists, "Information is not reachable: \(element)")
 }
 func openDownloadedNetworkBook(readium: Bool, ambiguous: Bool = false, large: Bool = false) -> XCUIApplication {
  let app = start(readium: readium, webUpdate: true, ambiguous: ambiguous, large: large)
  app.buttons["发现"].firstMatch.tap()
  let novel = app.staticTexts["架构验证小说"].firstMatch
  XCTAssertTrue(novel.waitForExistence(timeout: 15)); novel.tap()
  let download = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "下载全书 EPUB")).firstMatch
  reveal(download, app: app); download.tap()
  let begin = app.buttons["开始下载"]; reveal(begin, app: app); begin.tap()
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "EPUB 下载完成")).firstMatch.waitForExistence(timeout: 30))
  app.buttons["关闭"].tap(); app.buttons["书库"].firstMatch.tap()
  let more = app.buttons["更多操作：架构验证小说"]
  XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
  app.buttons["阅读"].firstMatch.tap()
  XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 30))
  return app
 }
 func openChapterUpdates(_ app: XCUIApplication) {
  app.buttons["返回"].firstMatch.tap()
  openBookManagement(app)
 }
 func openBookManagement(_ app: XCUIApplication) {
  let more = app.buttons["更多操作：架构验证小说"]; XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
  let updates = app.buttons["章节同步与更新"]; XCTAssertTrue(updates.waitForExistence(timeout: 10)); updates.tap()
  XCTAssertTrue(app.buttons["按目录核对章节"].waitForExistence(timeout: 15))
 }
 // 双向切换主题后，正文中央点按必须仍能隐藏并恢复控件。
 func testReadiumThemeSwitchPreservesCenterTap() {
  let app = openDownloadedNetworkBook(readium: true); defer { app.terminate() }
  for color in ["浅色", "深色", "浅色"] {
   let style = app.buttons["阅读样式"]
   XCTAssertTrue(style.waitForExistence(timeout: 15)); style.tap()
   let theme = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "阅读主题")).firstMatch
   for _ in 0..<10 {
    if theme.exists && theme.isHittable { break }
    app.collectionViews.allElementsBoundByIndex.last?.swipeUp()
   }
   XCTAssertTrue(theme.isHittable); theme.tap(); app.buttons[color].tap()
   app.navigationBars["阅读样式"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
   XCTAssertTrue(style.waitForExistence(timeout: 10))
   app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
   expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: style)
   waitForExpectations(timeout: 5)
   app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
   XCTAssertTrue(style.waitForExistence(timeout: 5))
  }
 }
 func checkNetworkEnd(readium: Bool) {
  let app = openDownloadedNetworkBook(readium: readium); defer { app.terminate() }
  let slider = app.sliders.firstMatch
  XCTAssertTrue(slider.waitForExistence(timeout: 15)); slider.adjust(toNormalizedSliderPosition: 1)
  let end = app.staticTexts["已读完本机已下载章节"]
  for _ in 0..<15 {
   if end.exists { break }
   app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)).tap()
  }
  XCTAssertTrue(end.waitForExistence(timeout: 15))
  XCTAssertTrue(app.buttons["更新至最新章节"].exists)
  XCTAssertTrue(app.staticTexts["暂无法确认未下载数量，请核对本机章节。"].exists)
  let confirm = app.buttons["确认这两个章节对应"]
  reveal(confirm, app: app); confirm.tap()
  let confirmed = app.staticTexts["已保存该章节对应，原进度和书签已尝试迁移。"]
  revealInfo(confirmed, app: app)
  XCTAssertTrue(confirmed.waitForExistence(timeout: 15))
  let remaining = app.staticTexts["还有 1 章未下载"]; revealInfo(remaining, app: app, up: false)
  XCTAssertTrue(remaining.waitForExistence(timeout: 15))
  let update = app.buttons["更新至最新章节"]
  reveal(update, app: app, up: false); update.tap()
  let updated = app.staticTexts["EPUB 已更新，阅读位置按已确认章节恢复。可核对新版章节后继续阅读。"]
  revealInfo(updated, app: app)
  XCTAssertTrue(updated.waitForExistence(timeout: 30))
  let verify = app.buttons["按目录核对章节"]
  let verified = app.staticTexts["章节核对完成。"]
  for _ in 0..<3 {
   if verified.exists { break }
   for _ in 0..<3 { app.swipeDown() }
   reveal(verify, app: app); verify.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
   for _ in 0..<4 { if verified.exists { break }; app.swipeUp() }
  }
  XCTAssertTrue(verified.waitForExistence(timeout: 30))
  let continuation = app.buttons["继续阅读新章节"]; reveal(continuation, app: app, up: false); continuation.tap()
  XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 15))
  openChapterUpdates(app)
  XCTAssertTrue(app.staticTexts["本机已包含网站当前全部章节"].waitForExistence(timeout: 15))
  app.buttons["关闭"].tap()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("正文请求 0"))
  zeroExternalRequests(app)
 }

 func testNetworkEPUBManualCandidatesAndNext() {
  let app = openDownloadedNetworkBook(readium: false, ambiguous: true); defer { app.terminate() }
  openChapterUpdates(app)
  let verify = app.buttons["按目录核对章节"]; reveal(verify, app: app); verify.tap()
  let pending = app.staticTexts["web-epub-pending-count"]; revealInfo(pending, app: app)
  XCTAssertEqual(pending.label, "待确认 2 章")
  func choose(_ label: String) {
   let picker = app.buttons["web-epub-remote-selection"]; reveal(picker, app: app); picker.tap()
   let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch; XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription); option.tap()
   if !app.buttons["关闭"].waitForExistence(timeout: 3) { app.navigationBars.buttons.element(boundBy: 0).tap() }
  }
  choose("第 1 章 · 幕间")
  let confirm = app.buttons["确认这两个章节对应"]; reveal(confirm, app: app); confirm.tap()
  revealInfo(pending, app: app, up: false); XCTAssertEqual(pending.label, "待确认 1 章")
  let local = app.buttons["web-epub-local-selection"]; reveal(local, app: app)
  XCTAssertTrue(local.label.contains("第 2 项"))
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("正文请求 0"))
  choose("第 2 章 · 幕间")
  let preview = app.buttons["查看所选章节正文"]; reveal(preview, app: app); preview.tap()
  XCTAssertTrue(app.staticTexts["本机正文"].waitForExistence(timeout: 15))
  XCTAssertTrue(app.staticTexts["网站正文"].exists)
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("正文请求 1"))
  reveal(confirm, app: app); confirm.tap()
  revealInfo(pending, app: app, up: false); XCTAssertEqual(pending.label, "待确认 0 章")
  XCTAssertFalse(app.buttons["确认这两个章节对应"].exists)
  zeroExternalRequests(app)
 }

 func testMovedWenkuEPUBKeepsOriginalReader() {
  let app = openDownloadedNetworkBook(readium: false); defer { app.terminate() }
  app.buttons["返回"].firstMatch.tap()
  let more = app.buttons["更多操作：架构验证小说"]
  XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
  app.buttons["移至文库"].tap()
  let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-book-wenku:")).firstMatch
  XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
  XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 20))
  app.buttons["目录"].tap()
  XCTAssertFalse(app.buttons["章节更新"].exists)
  app.buttons["关闭"].tap()
  let slider = app.sliders.firstMatch
  XCTAssertTrue(slider.waitForExistence(timeout: 10)); slider.adjust(toNormalizedSliderPosition: 1)
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)).tap()
  XCTAssertFalse(app.staticTexts["已读完本机已下载章节"].exists)
  zeroExternalRequests(app)
 }
 func testNativeNetworkEPUBEndAndUpdate() { checkNetworkEnd(readium: false) }
 func testReadiumNetworkEPUBEndAndUpdate() { checkNetworkEnd(readium: true) }
 func testBookMenuManagementAvoidsBodyRescan() {
  let app = openDownloadedNetworkBook(readium: false); defer { app.terminate() }
  openChapterUpdates(app)
  let status = app.staticTexts["architecture-validation-status"]
  XCTAssertTrue(status.label.contains("本机正文 0"))
  let verify = app.buttons["按目录核对章节"]; reveal(verify, app: app); verify.tap()
  let complete = app.staticTexts["章节核对完成。"]; revealInfo(complete, app: app)
  XCTAssertTrue(complete.waitForExistence(timeout: 20))
  XCTAssertTrue(status.label.contains("本机正文 1"))
  app.buttons["关闭"].tap(); openBookManagement(app)
  XCTAssertTrue(app.staticTexts["还有 1 章未下载"].waitForExistence(timeout: 15))
  XCTAssertTrue(status.label.contains("本机正文 1"))
  let check = app.buttons["重新检查更新"]; reveal(check, app: app); check.tap()
  XCTAssertTrue(app.staticTexts["还有 1 章未下载"].waitForExistence(timeout: 15))
  XCTAssertTrue(status.label.contains("本机正文 1"))
  XCTAssertTrue(status.label.contains("正文请求 0"))
  app.buttons["关闭"].tap()
  let more = app.buttons["更多操作：架构验证小说"]; more.tap(); app.buttons["阅读"].firstMatch.tap()
  let toc = app.buttons["目录"]; XCTAssertTrue(toc.waitForExistence(timeout: 15)); toc.tap()
  XCTAssertFalse(app.buttons["章节更新"].exists)
  zeroExternalRequests(app)
 }
 func testLargeBookMenuBatchVerification() {
  let app = openDownloadedNetworkBook(readium: false, large: true); defer { app.terminate() }
  openChapterUpdates(app)
  let status = app.staticTexts["architecture-validation-status"]
  XCTAssertTrue(status.label.contains("本机正文 0"))
  let verify = app.buttons["按目录核对章节"]; reveal(verify, app: app); verify.tap()
  let complete = app.staticTexts["章节核对完成。"]; revealInfo(complete, app: app)
  XCTAssertTrue(complete.waitForExistence(timeout: 40))
  XCTAssertTrue(status.label.contains("本机正文 130"))
  XCTAssertTrue(status.label.contains("批次 3"))
  app.buttons["关闭"].tap(); openBookManagement(app)
  XCTAssertTrue(app.staticTexts["还有 1 章未下载"].waitForExistence(timeout: 15))
  XCTAssertTrue(status.label.contains("本机正文 130"))
  XCTAssertTrue(status.label.contains("批次 3"))
  XCTAssertTrue(status.label.contains("正文请求 0"))
  zeroExternalRequests(app)
 }
 func testLegacyUpdateRequiresExplicitOptions() {
  let app = openDownloadedNetworkBook(readium: false); app.terminate()
  app.launchArguments = ["-architectureValidation", "-architectureWebEPUBUpdate", "-architectureLegacyWebEPUB"]
  app.launch(); defer { app.terminate() }
  app.buttons["书库"].firstMatch.tap()
  let more = app.buttons["更多操作：架构验证小说"]; XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
  app.buttons["更新到最新章节"].tap()
  let select = app.buttons["选择语言和译源"]; XCTAssertTrue(select.waitForExistence(timeout: 10)); select.tap()
  let confirm = app.buttons["确认并更新 EPUB"]; XCTAssertTrue(confirm.waitForExistence(timeout: 15)); XCTAssertFalse(confirm.isEnabled)
  app.buttons["译文"].tap(); XCTAssertFalse(confirm.isEnabled)
  app.buttons["取消"].tap()
  let status = app.staticTexts["architecture-validation-status"]
  XCTAssertTrue(status.label.contains("EPUB请求 0"))
  openBookManagement(app)
  let update = app.buttons["更新至最新章节"]; reveal(update, app: app); update.tap()
  XCTAssertTrue(confirm.waitForExistence(timeout: 15)); XCTAssertFalse(confirm.isEnabled)
  app.buttons["双语"].tap(); app.buttons["GPT"].tap(); XCTAssertTrue(confirm.isEnabled); confirm.tap()
  let success = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "文件内容没有变化，原阅读位置保留。", "EPUB 已更新，阅读位置按已确认章节恢复。可核对新版章节后继续阅读。")).firstMatch
  revealInfo(success, app: app); XCTAssertTrue(success.waitForExistence(timeout: 30))
  reveal(update, app: app, up: false); update.tap()
  expectation(for: NSPredicate(format: "label CONTAINS %@", "EPUB请求 2"), evaluatedWith: status)
  waitForExpectations(timeout: 15)
  revealInfo(success, app: app); XCTAssertTrue(success.waitForExistence(timeout: 30))
  XCTAssertFalse(app.navigationBars["选择更新设置"].exists)
  app.buttons["关闭"].tap(); more.tap(); app.buttons["更新到最新章节"].tap()
  XCTAssertTrue(app.buttons["重新获取并更新 EPUB"].waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testMenuUpdateInheritsConfirmedChapterLocally() {
  let app = openDownloadedNetworkBook(readium: false); defer { app.terminate() }
  openChapterUpdates(app)
  let confirm = app.buttons["确认这两个章节对应"]; reveal(confirm, app: app); confirm.tap()
  let pending = app.staticTexts["web-epub-pending-count"]; revealInfo(pending, app: app, up: false)
  XCTAssertEqual(pending.label, "待确认 0 章")
  XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 15)); app.buttons["关闭"].tap()
  let more = app.buttons["更多操作：架构验证小说"]; XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
  app.buttons["更新到最新章节"].tap()
  let update = app.buttons["重新获取并更新 EPUB"]; XCTAssertTrue(update.waitForExistence(timeout: 10)); update.tap()
  XCTAssertTrue(app.alerts["EPUB 更新"].waitForExistence(timeout: 30)); app.buttons["好"].tap()
  more.tap(); app.buttons["阅读"].firstMatch.tap()
  openChapterUpdates(app)
  revealInfo(pending, app: app); XCTAssertEqual(pending.label, "待确认 1 章")
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("正文请求 0"))
  zeroExternalRequests(app)
 }
 func testManualWebNovelEPUBUpdate() {
  let app = start(); defer { app.terminate() }
  app.buttons["发现"].firstMatch.tap()
  let novel = app.staticTexts["架构验证小说"].firstMatch
  XCTAssertTrue(novel.waitForExistence(timeout: 15)); novel.tap()
  let download = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "下载全书 EPUB")).firstMatch
  reveal(download, app: app); download.tap()
  let begin = app.buttons["开始下载"]; reveal(begin, app: app); begin.tap()
  let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "EPUB 下载完成")).firstMatch
  XCTAssertTrue(completed.waitForExistence(timeout: 30))
  app.buttons["关闭"].tap()
  app.buttons["书库"].firstMatch.tap()
  let more = app.buttons["更多操作：架构验证小说"]
  XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
  let update = app.buttons["更新到最新章节"]
  XCTAssertTrue(update.waitForExistence(timeout: 10)); update.tap()
  let confirm = app.buttons["重新获取并更新 EPUB"]
  XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
  XCTAssertTrue(app.alerts["EPUB 更新"].waitForExistence(timeout: 30))
  XCTAssertFalse(app.alerts["操作失败"].exists)
  app.buttons["好"].tap()
  XCTAssertTrue(more.waitForExistence(timeout: 10))
  more.tap()
  let cloud = app.buttons["从 WebDAV 获取新版 EPUB"]
  XCTAssertTrue(cloud.waitForExistence(timeout: 10)); cloud.tap()
  let fetch = app.buttons["取回云端 EPUB 并合并进度、书签"]
  XCTAssertTrue(fetch.waitForExistence(timeout: 10)); fetch.tap()
  XCTAssertTrue(app.alerts["操作失败"].waitForExistence(timeout: 15))
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请先开启 WebDAV")).firstMatch.exists)
  app.buttons["好"].tap()
  XCTAssertTrue(more.waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testDiscoveryCommentsDownloadAndLibrary() {
  let app = start(); defer { app.terminate() }
  openNovel(app)
  let comments = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{8bc4}\u{8bba}\u{533a}")).firstMatch
  reveal(comments, app: app); comments.tap()
  XCTAssertTrue(app.navigationBars["\u{8bc4}\u{8bba}\u{533a}"].waitForExistence(timeout: 10))
  let editor = app.textViews.firstMatch
  XCTAssertTrue(editor.waitForExistence(timeout: 10)); reveal(editor, app: app); editor.tap()
  editor.typeText("architecture-validation-comment")
  app.buttons["\u{53d1}\u{9001}"].tap()
  XCTAssertTrue(app.staticTexts["architecture-validation-comment"].firstMatch.waitForExistence(timeout: 10))
  app.navigationBars.buttons.element(boundBy: 0).tap()
  let download = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{4e0b}\u{8f7d}\u{5168}\u{4e66} EPUB")).firstMatch
  reveal(download, app: app, up: false); download.tap()
  XCTAssertTrue(app.navigationBars["\u{4e0b}\u{8f7d}\u{5168}\u{4e66}"].waitForExistence(timeout: 10))
  let begin = app.buttons["\u{5f00}\u{59cb}\u{4e0b}\u{8f7d}"]; reveal(begin, app: app); begin.tap()
  let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "EPUB \u{4e0b}\u{8f7d}\u{5b8c}\u{6210}")).firstMatch
  XCTAssertTrue(completed.waitForExistence(timeout: 30))
  app.buttons["\u{5173}\u{95ed}"].tap()
  app.navigationBars.buttons.element(boundBy: 0).tap()
  app.tabBars.buttons["\u{4e66}\u{5e93}"].tap()
  XCTAssertTrue(app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch.waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testCommunityUsesReplacementPostAndReplies() {
  let app = start(); defer { app.terminate() }
  app.tabBars.buttons["\u{793e}\u{533a}"].tap()
  let post = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5e16}\u{5b50}"].firstMatch
  XCTAssertTrue(post.waitForExistence(timeout: 15)); post.tap()
  XCTAssertTrue(app.staticTexts["\u{8fd9}\u{662f}\u{66ff}\u{4ee3}\u{670d}\u{52a1}\u{63d0}\u{4f9b}\u{7684}\u{5e16}\u{5b50}\u{6b63}\u{6587}\u{3002}"].firstMatch.waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testReadiumOnlineChapterFromReplacement() {
  let app = start(readium: true); defer { app.terminate() }
  openNovel(app)
  let read = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{7ee7}\u{7eed}\u{9605}\u{8bfb}")).firstMatch
  reveal(read, app: app); read.tap()
  XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
  let body = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\u{7ae0}\u{8282}\u{83b7}\u{53d6}\u{4e0d}\u{7ecf}\u{8fc7}\u{771f}\u{5b9e}\u{670d}\u{52a1}\u{5668}")).firstMatch
  XCTAssertTrue(body.waitForExistence(timeout: 30), "Readium must display replacement chapter text")
  zeroExternalRequests(app)
 }
 func testReplacementFailureAndRetry() {
  let app = start(failSearch: true); defer { app.terminate() }
  app.tabBars.buttons["\u{53d1}\u{73b0}"].tap()
  let retry = app.buttons["\u{91cd}\u{8bd5}"].firstMatch
  XCTAssertTrue(retry.waitForExistence(timeout: 15)); retry.tap()
  XCTAssertTrue(app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch.waitForExistence(timeout: 15))
  zeroExternalRequests(app)
 }
 func testReadiumTXTWithIsolatedLocalLibrary() {
  let app = start(readium: true, txt: true); defer { app.terminate() }
  let book = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}TXT"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
  XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
  let body = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\u{672c}\u{5730}TXT\u{9a8c}\u{8bc1}\u{6b63}\u{6587}")).firstMatch
  XCTAssertTrue(body.waitForExistence(timeout: 30))
  zeroExternalRequests(app)
 }
}
''', encoding='utf-8')
if args.library_archive or args.library_delete:
    subprocess.run(['xcrun','simctl','terminate',args.device,'cc.novelia.ios.architecture-validation'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data_root = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,
                                            'cc.novelia.ios.architecture-validation','data'], text=True).strip())
    support = data_root/'Library/Application Support'
    shutil.rmtree(support, ignore_errors=True)
    library_dir = support/'WenkuEPUB'
    library_dir.mkdir(parents=True, exist_ok=True)
    if args.library_delete:
        for filename, title in [('sample-a.epub', '验收样本甲'), ('sample-b.epub', '验收样本乙')]:
            with zipfile.ZipFile(library_dir/filename, 'w') as archive:
                archive.writestr('mimetype', 'application/epub+zip')
                archive.writestr('META-INF/container.xml', '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
                archive.writestr('book.opf', f'<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">{filename}</dc:identifier><dc:title>{title}</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>')
                archive.writestr('chapter.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1><p>用于删除回归的合成正文。</p></body></html>')
    else:
        samples = Path(__file__).resolve().parents[1]/'build/acceptance/1.0.0/samples'
        for filename, sample in (('sample-a.epub', '01-正常-三章-带封面.epub'), ('sample-b.epub', '03-长章节-单章约五万字.epub')):
            shutil.copyfile(samples/sample, library_dir/filename)
    reference = time.time() - 978307200.0
    records = [
        {'id': str(uuid.uuid4()).upper(), 'title': '验收样本甲', 'filename': 'sample-a.epub',
         'addedAt': reference, 'metadataLoaded': True, 'fileFormat': 'epub'},
        {'id': str(uuid.uuid4()).upper(), 'title': '验收样本乙', 'filename': 'sample-b.epub',
         'addedAt': reference - 60, 'metadataLoaded': True, 'fileFormat': 'epub'},
    ]
    (library_dir/'library.json').write_text(json.dumps(records), encoding='utf-8')
    (r/'TapTests.swift').write_text(r'''import XCTest
final class TapTests: XCTestCase {
 let bundle = "cc.novelia.ios.architecture-validation"
 func start() -> XCUIApplication {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation"]
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 20))
  return app
 }
 func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
   if app.buttons["拷贝"].exists || app.otherElements["ActivityListView"].exists { return true }
   RunLoop.current.run(until: Date().addingTimeInterval(0.5))
  }
  return false
 }
 func selectedCount(_ app: XCUIApplication, _ count: Int) {
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已选 \(count) 本")).firstMatch.waitForExistence(timeout: 20))
 }
 func beginSelection(_ app: XCUIApplication, title: String) {
  let row = app.staticTexts[title].firstMatch
  XCTAssertTrue(row.waitForExistence(timeout: 20)); row.press(forDuration: 0.8)
  selectedCount(app, 1)
 }
 func library(_ app: XCUIApplication) { app.tabBars.buttons["书库"].tap() }
 func shot(_ name: String) {
  let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
  attachment.name = name
  attachment.lifetime = .keepAlways
  add(attachment)
 }
 func seriesSegment(_ app: XCUIApplication) {
  let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "系列")).firstMatch
  XCTAssertTrue(segment.waitForExistence(timeout: 20)); segment.tap()
 }
 func booksSegment(_ app: XCUIApplication) {
  let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "全部书籍")).firstMatch
  XCTAssertTrue(segment.waitForExistence(timeout: 20)); segment.tap()
 }
 func testLibraryBatchArchiveAndSeries() {
  var app = start()
  library(app)
  XCTAssertTrue(app.staticTexts["验收样本甲"].firstMatch.waitForExistence(timeout: 20))
  XCTAssertTrue(app.staticTexts["验收样本乙"].firstMatch.waitForExistence(timeout: 20))
  // 顶部“选择”按钮也能进入多选，此时未选中任何书。
  let selectButton = app.buttons["选择"]
  XCTAssertTrue(selectButton.waitForExistence(timeout: 20), "书库右上角应有“选择”按钮")
  selectButton.tap()
  selectedCount(app, 0)
  XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 20)); app.buttons["完成"].tap()

  // 书库多选：全选两本后压缩分享。
  beginSelection(app, title: "验收样本甲")
  app.buttons["全选"].tap()
  selectedCount(app, 2)
  shot("library-multiselect")
  app.buttons["压缩分享"].tap()
  XCTAssertTrue(waitForShareSheet(app), "压缩两本书后应打开系统分享面板")
  shot("library-share-sheet")
  app.terminate()
  // 新建系列并压缩分享整个系列。
  app = start()
  library(app)
  beginSelection(app, title: "验收样本甲")
  app.buttons["移入系列"].tap()
  let newSeries = app.buttons["新建系列…"]
  XCTAssertTrue(newSeries.waitForExistence(timeout: 20)); newSeries.tap()
  let field = app.textFields.firstMatch
  XCTAssertTrue(field.waitForExistence(timeout: 20))
  field.typeText("验收系列")
  app.buttons["创建并移入"].tap()
  seriesSegment(app)
  let series = app.staticTexts["验收系列"].firstMatch
  XCTAssertTrue(series.waitForExistence(timeout: 20))
  series.press(forDuration: 0.8)
  let shareSeries = app.buttons["压缩后分享"]
  XCTAssertTrue(shareSeries.waitForExistence(timeout: 20))
  shot("series-context-menu")
  shareSeries.tap()
  XCTAssertTrue(waitForShareSheet(app), "系列长按压缩分享应打开系统分享面板")
  shot("series-share-sheet")
  app.terminate()
  // 系列详情批量移出，再在书库批量删除。
  app = start()
  library(app)
  seriesSegment(app)
  let seriesAgain = app.staticTexts["验收系列"].firstMatch
  XCTAssertTrue(seriesAgain.waitForExistence(timeout: 20)); seriesAgain.tap()
  beginSelection(app, title: "验收样本甲")
  // 系列里只有一本，进入多选即为全选。
  XCTAssertTrue(app.buttons["取消全选"].waitForExistence(timeout: 20))
  selectedCount(app, 1)
  shot("series-detail-multiselect")
  app.buttons["移出系列"].tap()
  app.navigationBars.buttons.element(boundBy: 0).tap()
  booksSegment(app)
  XCTAssertTrue(app.staticTexts["验收样本甲"].firstMatch.waitForExistence(timeout: 20))
  XCTAssertTrue(app.staticTexts["验收样本乙"].firstMatch.waitForExistence(timeout: 20))
  beginSelection(app, title: "验收样本乙")
  app.buttons["全选"].tap()
  selectedCount(app, 2)
  app.buttons["删除"].tap()
  let localOnly = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "仅删除本机")).firstMatch
  XCTAssertTrue(localOnly.waitForExistence(timeout: 20)); localOnly.tap()
  XCTAssertTrue(app.staticTexts["书库还没有书"].firstMatch.waitForExistence(timeout: 20))
  app.terminate()
 }
}
''')
if args.performance:
    performance = r'''import XCTest
final class TapTests: XCTestCase {
 static var seeded = false
 let bundle = "cc.novelia.ios.architecture-validation"
 func configured() -> XCUIApplication {
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation"]
  return app
 }
 func seed(large: Bool = false) {
  let app = configured()
  app.launchArguments += ["-resetArchitectureValidation", "-seedPerformanceLibrary", "-performanceLibraryCount", "LIBRARY_COUNT"]
  if large { app.launchArguments.append("-performanceLargeTXT") }
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 60))
  app.terminate()
 }
 override func setUpWithError() throws {
  continueAfterFailure = false
  if !Self.seeded { seed(); Self.seeded = true }
 }
 func options() -> XCTMeasureOptions {
  let options = XCTMeasureOptions(); options.iterationCount = ITERATIONS; return options
 }
 func testALaunch() {
  let app = configured()
  measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options()) {
   app.launch(); app.terminate()
  }
 }
 func testBScroll() throws {
  if LIBRARY_COUNT == 0 { throw XCTSkip("Empty library has no scrolling workload") }
  let app = configured(); app.launch(); defer { app.terminate() }
  let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-book-")).firstMatch
  XCTAssertTrue(row.waitForExistence(timeout: 30))
  measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
                    XCTOSSignpostMetric.scrollDecelerationMetric], options: options()) {
   app.swipeUp(); app.swipeDown()
  }
 }
 func testCLaunchAndOpenLargeTXT() {
  seed(large: true)
  let app = configured()
  measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options()) {
   app.launch()
   let book = app.staticTexts["基准长 TXT"].firstMatch
   XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
   let body = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "性能基准正文")).firstMatch
   XCTAssertTrue(body.waitForExistence(timeout: 60))
   app.terminate()
  }
 }
 func waitForEPUB(_ app: XCUIApplication) {
  let next = app.buttons["下一页"]
  XCTAssertTrue(next.waitForExistence(timeout: 30))
  let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
  XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
 }
 func testDLaunchAndOpenSampleEPUB() {
  let app = configured(); app.launchArguments.append("-openEPUBPrototype")
  // 样例文件生成不计时；测量后续进程启动至分页可操作，默认 Yuedu 引擎。
  app.launch(); waitForEPUB(app); app.terminate()
  measure(metrics: [XCTClockMetric()], options: options()) {
   app.launch(); waitForEPUB(app); app.terminate()
  }
 }
}
'''.replace('LIBRARY_COUNT', str(args.library_count)).replace('ITERATIONS', str(args.iterations))
    (r/'TapTests.swift').write_text(performance)
def ID(n):return f'A{n:023X}'
objects=[]
def obj(n,txt):objects.append(ID(n)+' = {'+txt+'};')
obj(1,f'isa=PBXProject; buildConfigurationList={ID(20)}; compatibilityVersion="Xcode 14.0"; mainGroup={ID(2)}; productRefGroup={ID(3)}; projectDirPath=""; projectRoot=""; targets=({ID(10)},{ID(11)});')
obj(2,f'isa=PBXGroup; children=({ID(4)},{ID(5)},{ID(3)}); sourceTree="<group>";')
obj(3,f'isa=PBXGroup; name=Products; children=({ID(6)},{ID(7)}); sourceTree="<group>";')
obj(4,'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapRegression.swift; sourceTree="<group>";')
obj(5,'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapTests.swift; sourceTree="<group>";')
obj(6,'isa=PBXFileReference; explicitFileType=wrapper.application; path=TapRegression.app; sourceTree=BUILT_PRODUCTS_DIR;')
obj(7,'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=TapTests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
obj(8,f'isa=PBXBuildFile; fileRef={ID(4)};');obj(9,f'isa=PBXBuildFile; fileRef={ID(5)};')
obj(10,f'isa=PBXNativeTarget; name=TapRegression; productName=TapRegression; productReference={ID(6)}; productType="com.apple.product-type.application"; buildConfigurationList={ID(21)}; buildPhases=({ID(12)}); dependencies=();')
obj(11,f'isa=PBXNativeTarget; name=TapTests; productName=TapTests; productReference={ID(7)}; productType="com.apple.product-type.bundle.ui-testing"; buildConfigurationList={ID(22)}; buildPhases=({ID(13)}); dependencies=({ID(15)});')
obj(12,f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(8)}); runOnlyForDeploymentPostprocessing=0;');obj(13,f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(9)}); runOnlyForDeploymentPostprocessing=0;')
obj(14,f'isa=PBXContainerItemProxy; containerPortal={ID(1)}; proxyType=1; remoteGlobalIDString={ID(10)}; remoteInfo=TapRegression;')
obj(15,f'isa=PBXTargetDependency; target={ID(10)}; targetProxy={ID(14)};')
settings='SWIFT_VERSION=5.0; SDKROOT=iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET=17.0; CODE_SIGNING_ALLOWED=NO; GENERATE_INFOPLIST_FILE=YES; TARGETED_DEVICE_FAMILY=1; PRODUCT_NAME="$(TARGET_NAME)";'
for n,extra in [(30,''),(31,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.library-regression"; INFOPLIST_KEY_UILaunchScreen_Generation=YES;'),(32,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.library-regression.tests"; TEST_TARGET_NAME=TapRegression;')]:obj(n,'isa=XCBuildConfiguration; name=Debug; buildSettings={'+settings+extra+'};')
for n,c in [(20,30),(21,31),(22,32)]:obj(n,f'isa=XCConfigurationList; buildConfigurations=({ID(c)}); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
p=r/'TapRegression.xcodeproj';p.mkdir(exist_ok=True);(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={'+''.join(objects)+'}; rootObject='+ID(1)+';}')
d=p/'xcshareddata/xcschemes';d.mkdir(parents=True,exist_ok=True)
def ref(n,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ID(n)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:TapRegression.xcodeproj"/>'
(d/'TapTests.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction parallelizeBuildables="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">'+ref(10,'TapRegression.app')+'</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">'+ref(11,'TapTests.xctest')+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+ref(11,'TapTests.xctest')+'</TestableReference></Testables></TestAction></Scheme>')
sample = None
previous_sample = None
if args.epub_failure:
    subprocess.run(['xcrun','simctl','terminate',args.device,'cc.novelia.ios.architecture-validation'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data_root = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,
                                            'cc.novelia.ios.architecture-validation','data'], text=True).strip())
    sample = data_root/'Documents/prototype-sample.epub'
    sample.parent.mkdir(parents=True, exist_ok=True)
    previous_sample = sample.read_bytes() if sample.exists() else None
    if args.epub_failure == 'archive':
        sample.write_bytes(b'PK invalid synthetic EPUB')
    elif args.epub_failure == 'spine':
        with zipfile.ZipFile(sample, 'w') as archive:
            archive.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
            archive.writestr('book.opf', '<package><manifest><item id="a" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine></spine></package>')
            archive.writestr('c1.xhtml', '<html><body><p>不会被读取的章节。</p></body></html>')
    else:
        with zipfile.ZipFile(sample, 'w') as archive:
            archive.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
            archive.writestr('book.opf', '<package><manifest><item id="a" href="missing.xhtml" media-type="application/xhtml+xml"/><item id="b" href="readable.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>')
            archive.writestr('nav.xhtml', '<nav><a href="missing.xhtml">缺失章节</a><a href="readable.xhtml">可读章节</a></nav>')
            archive.writestr('readable.xhtml', '<html><body>' + '<p>异常章节之后仍能阅读的合成正文。</p>' * 120 + '</body></html>')
    if args.epub_failure == 'archive':
        body = r'''
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法打开 EPUB 压缩包")).firstMatch.waitForExistence(timeout: 20))
  app.buttons["复制错误说明"].tap()
  app.buttons["重新打开"].tap()
  XCTAssertTrue(app.buttons["重新打开"].waitForExistence(timeout: 20))
'''
    elif args.epub_failure == 'spine':
        body = r'''
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "spine 为空")).firstMatch.waitForExistence(timeout: 30), "空 spine 必须在 Readium 下显示可读错误而不是闪退")
  XCTAssertTrue(app.buttons["复制错误说明"].exists)
  app.buttons["复制错误说明"].tap()
  XCTAssertTrue(app.buttons["重新打开"].exists, "EPUB 失败页必须有重新打开入口")
  app.buttons["关闭阅读器"].tap()
  XCTAssertTrue(app.tabBars.buttons["书库"].waitForExistence(timeout: 15))
  return
'''
    else:
        body = r'''
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "章节文件缺失：missing.xhtml")).firstMatch.waitForExistence(timeout: 20))
  app.buttons["复制错误说明"].tap()
  app.buttons["重试"].tap()
  XCTAssertTrue(app.buttons["选择其他章节"].waitForExistence(timeout: 20))
  app.buttons["选择其他章节"].tap()
  app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "可读章节")).firstMatch.tap()
  XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法读取或排版")).firstMatch.waitForExistence(timeout: 5), "跳到可读章节后失败页必须消失")
  XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相邻章节加载失败")).firstMatch.exists, "永久缺失的相邻章节不应弹重试横幅")
  let next = app.buttons["下一页"]
  XCTAssertTrue(next.waitForExistence(timeout: 30))
  expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
  waitForExpectations(timeout: 30)
  XCTAssertFalse(app.buttons["关闭阅读器"].exists)
  next.tap()
'''
    launch_args = ('["-architectureValidation", "-resetArchitectureValidation", "-openEPUBPrototype"'
                   + (', "-architectureReadium"' if args.epub_failure == 'spine' else '') + ']')
    (r/'TapTests.swift').write_text(r'''import XCTest
final class TapTests: XCTestCase {
 func testBrokenEPUBRecovery() {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: "cc.novelia.ios.architecture-validation")
  app.launchArguments = ''' + launch_args + r'''
  app.launch(); defer { app.terminate() }
''' + body + r'''
  let back = app.buttons["关闭阅读器"].exists ? app.buttons["关闭阅读器"] : app.buttons["返回"]
  back.tap()
  XCTAssertTrue(app.tabBars.buttons["书库"].waitForExistence(timeout: 10))
 }
}
''')
if args.library_delete:
    subprocess.run(['xcrun','simctl','spawn',args.device,'defaults','write','cc.novelia.ios.architecture-validation','webdav.enabled','-bool','YES'],check=True)
    duplicate=dict(records[0]); duplicate['id']=str(uuid.uuid4()).upper(); duplicate['filename']='duplicate-a.epub'; duplicate['addedAt']-=120
    shutil.copyfile(library_dir/records[0]['filename'],library_dir/duplicate['filename'])
    records.append(duplicate)
    # 每条记录各有一张封面（含隐藏副本），删除后核对封面文件随书一并清除。
    png=b'\x89PNG\r\n\x1a\n'+b''.join(struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)) for t,d in
        [(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0)),(b'IDAT',zlib.compress(b'\x00\xff\xff\xff')),(b'IEND',b'')])
    for record in records:
        record['coverFilename']=f"cover-{record['id']}.png"
        (library_dir/record['coverFilename']).write_bytes(png)
    (library_dir/'library.json').write_text(json.dumps(records))
    cloud_dir=support/'WebDAVCloudBooks'
    cloud_dir.mkdir(parents=True,exist_ok=True)
    asset={'filename':records[0]['filename'],'hash':hashlib.sha256((library_dir/records[0]['filename']).read_bytes()).hexdigest()}
    cloud_record={k:v for k,v in records[0].items() if k!='coverFilename'}
    (cloud_dir/'index.json').write_text(json.dumps({'web':[],'wenku':[{'record':cloud_record,'assets':[asset]}]}))
    (r/'TapTests.swift').write_text(r"""import XCTest
final class TapTests:XCTestCase {
 func testLibraryDuplicateDeletionAndCloudFailure() {
  continueAfterFailure=false
  let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
  app.launchArguments=["-architectureValidation"]
  app.launch(); defer { app.terminate() }
  let row=app.staticTexts["验收样本甲"].firstMatch
  XCTAssertTrue(row.waitForExistence(timeout:20)); row.press(forDuration:0.8)
  let delete=app.buttons["删除"].firstMatch
  XCTAssertTrue(delete.waitForExistence(timeout:10)); delete.tap()
  let confirm=app.buttons["删除本机和云端副本"]
  XCTAssertTrue(confirm.waitForExistence(timeout:10)); confirm.tap()
  let banner=app.staticTexts["云端尚未删除"]
  XCTAssertTrue(banner.waitForExistence(timeout:15),"Cloud failure must remain visible")
  XCTAssertFalse(app.alerts["操作失败"].exists)
  XCTAssertTrue(app.buttons["重试"].firstMatch.isHittable)
  let menu=app.buttons["更多操作：验收样本甲"].firstMatch
  XCTAssertTrue(menu.waitForExistence(timeout:10)); menu.tap()
  XCTAssertTrue(app.buttons["下载"].firstMatch.waitForExistence(timeout:10), "All hidden local copies must be gone; no local reading action")
  XCTAssertFalse(app.buttons["阅读"].exists)
 }
}
""")

if args.epub_pagination:
    subprocess.run(['xcrun','simctl','terminate',args.device,'cc.novelia.ios.architecture-validation'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data_root = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,'cc.novelia.ios.architecture-validation','data'], text=True).strip())
    support = data_root/'Library/Application Support'
    shutil.rmtree(support, ignore_errors=True)
    library_dir = support/'WenkuEPUB'
    library_dir.mkdir(parents=True)
    with zipfile.ZipFile(library_dir/'pagination.epub', 'w') as z:
     z.writestr('mimetype','application/epub+zip')
     z.writestr('META-INF/container.xml','<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
     z.writestr('book.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">pagination-regression</dc:identifier><dc:title>分页连续性</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">2026-10-19T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'+''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(3))+'</manifest><spine>'+''.join(f'<itemref idref="c{i}"/>' for i in range(3))+'</spine></package>')
     z.writestr('nav.xhtml','<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>'+''.join(f'<li><a href="c{i}.xhtml">第{i+1}章</a></li>' for i in range(3))+'</ol></nav></body></html>')
     for chapter in range(3):
      pages=''.join(f'<section><p data-pagination-marker="{chapter*20+i+1}">PAGE_{chapter*20+i+1:03d}</p><p>这是连续性验证正文。每次翻页必须依次显示编号，不能跳过。</p></section>' for i in range(20))
      z.writestr(f'c{chapter}.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>分页</title><style>section { break-after: column; -webkit-column-break-after: always; page-break-after: always; }</style></head><body>'+pages+'</body></html>')
    (library_dir/'library.json').write_text(json.dumps([{'id':str(uuid.uuid4()).upper(),'title':'分页连续性','filename':'pagination.epub','addedAt':time.time()-978307200,'metadataLoaded':True,'fileFormat':'epub'}]))
    (r/'TapTests.swift').write_text(r"""import XCTest
    final class TapTests: XCTestCase {
     func testReadiumEPUBPageContinuity() {
      continueAfterFailure = false
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination"]
      app.launch(); defer { app.terminate() }
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20)); book.tap()
      XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:30))
      XCTAssertTrue(app.webViews.staticTexts["PAGE_001"].firstMatch.waitForExistence(timeout:30))
      sleep(3)
      let probe=app.staticTexts["readium-validation-visible-paragraphs"]
      XCTAssertTrue(probe.waitForExistence(timeout:20))
      func visible() -> [Int] {
       guard let data=probe.label.data(using:.utf8), let values=try? JSONSerialization.jsonObject(with:data) as? [Int] else { return [] }
       return values.sorted()
      }
      let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !visible().isEmpty },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:20),.completed)
      var previous=visible()
      XCTAssertEqual(previous.first,1)
      for backwards in [false,true] {
       for turn in 0..<32 {
        if backwards ? previous.first==1 : previous.last==60 { break }
        let before=probe.label
        let right=app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5))
        let left=app.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5))
        if turn % 2 == 0 { (backwards ? left : right).tap() }
        else { (backwards ? left : right).press(forDuration:0.05,thenDragTo:backwards ? right : left) }
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in probe.label != before && !visible().isEmpty },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:15),.completed,"Page turn did not settle")
        let current=visible()
        print("CONTINUITY backwards=\(backwards) turn=\(turn) before=\(previous) after=\(current)")
        guard let first=current.first, let last=current.last, let oldFirst=previous.first, let oldLast=previous.last else { return }
        if backwards {
         XCTAssertGreaterThanOrEqual(last,oldFirst-1,"Skipped paragraphs going backward")
         XCTAssertLessThan(first,oldFirst)
        } else {
         XCTAssertLessThanOrEqual(first,oldLast+1,"Skipped paragraphs going forward")
         XCTAssertGreaterThan(last,oldLast)
        }
        previous=current
       }
       XCTAssertEqual(backwards ? previous.first : previous.last,backwards ? 1 : 60)
      }
     }
     // 章中途在不同高度（含上下页边距）滑动翻页：只能在本章内翻一页，不能被外层章节切换接管而跳章。
     func testReadiumMidChapterSwipesStayInChapter() {
      continueAfterFailure = true
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination"]
      app.launch(); defer { app.terminate() }
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20)); book.tap()
      XCTAssertTrue(app.webViews.staticTexts["PAGE_001"].firstMatch.waitForExistence(timeout:30))
      sleep(3)
      let probe=app.staticTexts["readium-validation-visible-paragraphs"]
      XCTAssertTrue(probe.waitForExistence(timeout:20))
      func visible() -> [Int] {
       guard let data=probe.label.data(using:.utf8), let values=try? JSONSerialization.jsonObject(with:data) as? [Int] else { return [] }
       return values.sorted()
      }
      func settle(_ before: String) {
       let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in probe.label != before && !visible().isEmpty },object:nil)
       _ = XCTWaiter.wait(for:[changed],timeout:6)
       sleep(1)
      }
      // 每页显示 5 个编号、每章 20 个：点按 6 次到第二章第 3 页（31–35）。
      for _ in 0..<6 { let before=probe.label; app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap(); settle(before) }
      for dy in [0.5, 0.88, 0.94, 0.97, 0.06, 0.12] {
       for backwards in [true, false] {
        let before=probe.label
        let old=visible()
        let from=app.coordinate(withNormalizedOffset:CGVector(dx:backwards ? 0.2 : 0.8,dy:dy))
        let to=app.coordinate(withNormalizedOffset:CGVector(dx:backwards ? 0.8 : 0.2,dy:dy))
        from.press(forDuration:0.05,thenDragTo:to)
        settle(before)
        let now=visible()
        print("MARGIN_SWIPE dy=\(dy) backwards=\(backwards) before=\(old) after=\(now)")
        guard let oldFirst=old.first, let first=now.first else { continue }
        // 只检查起点在章中部的滑动；章首向前、章末向后本就应切章。
        if (backwards && (oldFirst-1)%20==0) || (!backwards && (oldFirst-1)%20>=15) { continue }
        // 起点在第二章中部，前后各一页都仍在第二章（编号 21–40）；跨章即为外层章节切换接管了滑动。
        XCTAssertEqual((first-1)/20, (oldFirst-1)/20, "Swipe at dy=\(dy) backwards=\(backwards) changed chapter: \(old) -> \(now)")
        XCTAssertLessThanOrEqual(abs(first-oldFirst), old.count, "Swipe at dy=\(dy) backwards=\(backwards) skipped pages: \(old) -> \(now)")
       }
      }
     }
    }
    """)
print(f'UI test artifacts: {r}', flush=True)
with (r / 'test.log').open('w') as log:
 try:
  subprocess.run(['xcodebuild','-project',str(p),'-scheme','TapTests','-destination',f'platform=iOS Simulator,id={args.device}','-derivedDataPath',str(r/'DerivedData'),'-parallel-testing-enabled','NO','test'] + ([f'-only-testing:{args.only_testing}'] if args.only_testing else []),stdout=log,stderr=subprocess.STDOUT,check=True)
 finally:
  if sample is not None:
   subprocess.run(['xcrun','simctl','terminate',args.device,'cc.novelia.ios.architecture-validation'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
   if previous_sample is None:
    sample.unlink(missing_ok=True)
   else:
    sample.write_bytes(previous_sample)
if args.library_delete:
    data_root = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,
                                            'cc.novelia.ios.architecture-validation','data'], text=True).strip())
    directory = data_root/'Library/Application Support/WenkuEPUB'
    remaining = json.loads((directory/'library.json').read_text())
    if len(remaining) != 1 or remaining[0]['title'] != '验收样本乙':
        raise SystemExit('Deletion left a hidden local duplicate; UI alone can hide it behind a cloud record')
    if (directory/'sample-a.epub').exists() or (directory/'duplicate-a.epub').exists():
        raise SystemExit('Deletion left a selected local file')
    covers = sorted(p.name for p in directory.glob('cover-*'))
    if covers != [remaining[0]['coverFilename']]:
        raise SystemExit(f'Deletion left or removed the wrong cover files: {covers}')
if args.library_archive:
    data_root = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,
                                            'cc.novelia.ios.architecture-validation','data'], text=True).strip())
    share_dir = data_root/'tmp/NoveliaShare'
    zips = sorted(share_dir.glob('*.zip')) if share_dir.exists() else []
    if not zips:
        raise SystemExit(f'No shared archive produced under {share_dir}')
    for archive_path in zips:
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            assert names, f'Empty archive: {archive_path}'
            assert all(not name.startswith('/') and '..' not in name.split('/') for name in names), f'Unsafe entry in {archive_path}: {names}'
            assert all(archive.getinfo(name).file_size > 0 for name in names), f'Empty entry in {archive_path}: {names}'
            print(f'archive {archive_path.name}: ' + ', '.join(names), flush=True)
if args.performance:
    metrics = subprocess.run(['xcrun','xcresulttool','get','test-results','metrics','--path',
                              str(next((r/'DerivedData/Logs/Test').glob('*.xcresult'))), '--compact'],
                             capture_output=True, text=True)
    root = Path(__file__).resolve().parents[1]
    digest = hashlib.sha256()
    for source in sorted([* (root/'Sources').rglob('*.swift'), * (root/'iOSApp').rglob('*.swift')]):
        digest.update(str(source.relative_to(root)).encode()); digest.update(source.read_bytes())
    info = plistlib.loads((Path(args.app)/'Info.plist').read_bytes())
    report = {'scope':'simulator_debug_ui_baseline', 'library_count':args.library_count,
              'iterations':args.iterations, 'source_sha256':digest.hexdigest(),
              'version':info.get('CFBundleShortVersionString'), 'build':info.get('CFBundleVersion'),
              'app_executable_sha256':hashlib.sha256((Path(args.app)/info['CFBundleExecutable']).read_bytes()).hexdigest(),
              'artifacts':str(r), 'device_id':args.device,
              'xcode_version':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
              'sdk':info.get('DTSDKName'),
              'limitations':['synthetic data and replacement backend','Debug build','not physical device or battery qualification',
                             'large TXT metric includes app launch and UI automation; no pass/fail performance thresholds']}
    if metrics.returncode == 0:
        report['metrics'] = json.loads(metrics.stdout)
    else:
        report['metrics_export_error'] = metrics.stderr[:1000]
    if args.result_json:
        args.result_json.parent.mkdir(parents=True, exist_ok=True)
        args.result_json.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    print('Actual App replacement-service UI flows passed')
