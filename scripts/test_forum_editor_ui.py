#!/usr/bin/env python3
"""Test the production editor with synthetic posts and a local mock; never writes to a forum."""
from pathlib import Path
import argparse
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix='NoveliaEditorRegression-'))
s = (Path(__file__).resolve().parents[1] / 'iOSApp/ForumViews.swift').read_text()
component = s[s.index('private struct ForumComposeView'):s.index('private extension String', s.index('private struct ForumComposeView'))]
fixture = 'import SwiftUI\nimport Combine\nprivate enum NoveliaStyle { static let paper = Color.white; static let brandGreen = Color.green; static let muted = Color.gray }\nprivate final class ForumAuthStore: ObservableObject { @Published var username: String? = "test-author"; @Published var isLoginPresented = false }\nprivate enum NoveliaForumSessionTokenVault { static func read() -> String? { nil } }\nprivate struct ForumTag: Identifiable { let id: Int64; let name: String; let sortOrder = 0 }\nprivate struct ForumCategory: Identifiable { let id: Int64; let title: String; let tags: [ForumTag] }\nprivate struct ForumPost { let id: Int64; let categoryId: Int64; let title: String; let content: String; let authorUsername: String; let tags: [ForumTag] }\nprivate struct ForumAPIClient {\n static var fail = false\n init(tokenProvider: @escaping () -> String?) {}\n func updatePost(id: Int64, categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost {\n  if Self.fail { throw NSError(domain: "Mock", code: 403, userInfo: [NSLocalizedDescriptionKey: "保存失败测试"]) }\n  return ForumPost(id: id, categoryId: categoryID, title: title, content: content, authorUsername: "test-author", tags: tagIDs.map { ForumTag(id: $0, name: "测试标签") })\n }\n func createPost(categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost { try await updatePost(id: 42, categoryID: categoryID, title: title, content: content, tagIDs: tagIDs) }\n}\nprivate struct ForumErrorOverlay: View {\n let message: String; let onDismiss: () -> Void\n var body: some View { VStack { Text(message); Button("关闭", action: onDismiss) }.padding().background(.white) }\n}\n@main struct TapRegressionApp: App { var body: some Scene { WindowGroup { TestScreen() } } }\nprivate struct TestScreen: View {\n @StateObject private var auth = ForumAuthStore()\n @State private var editing = false\n @State private var post = ForumPost(id: 42, categoryId: 7, title: "Original", content: "first\\nlast\\n", authorUsername: "test-author", tags: [ForumTag(id: 3, name: "测试标签")])\n var body: some View {\n  VStack {\n   Text("Saved: \\(post.title)")\n   Button("编辑") { ForumAPIClient.fail = false; editing = true }\n   Button("错误测试") { ForumAPIClient.fail = true; editing = true }\n  }\n  .sheet(isPresented: $editing) {\n   NavigationStack { ForumComposeView(categories: [ForumCategory(id: 7, title: "测试分类", tags: [ForumTag(id: 3, name: "测试标签")])], editingPost: post) { post = $0 } }\n  }\n  .environmentObject(auth)\n }\n}\n'
fixture = fixture.replace('import Combine', 'import Combine\nimport UIKit\nimport WebKit').replace('static let paper', 'static let ink = Color.black; static let card = Color.white; static let paper')
fixture = fixture.replace('let title: String; let tags: [ForumTag] }', 'let title: String; let slug = "novel"; let tags: [ForumTag] }')
fixture = fixture.replace(' static var fail = false', ' func categories() async throws -> [ForumCategory] { [ForumCategory(id: 7, title: "测试分类", tags: [ForumTag(id: 3, name: "测试标签")])] }\n static var fail = false')
fixture = fixture.replace('.sheet(isPresented: $editing)', '.fullScreenCover(isPresented: $editing)')
fixture += 'private struct ForumView: View { var initialCategory: String = ""; var initialQuery: String = ""; var body: some View { Text("分类: \(initialCategory) 搜索: \(initialQuery)").navigationTitle("分类页面") } }\n'
fixture += 'private enum ForumMarkdownMode { case article, comment }\nprivate struct ForumMarkdownBody: View { let markdown: String; var mode: ForumMarkdownMode = .article; var body: some View { Text((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)) } }\n'
support = s[s.index('private struct ForumComposeNotice'):s.index('private struct ForumCommentEditorSheet')]
editor = s[s.index('private struct ForumMarkdownEditor'):s.index('private struct ForumMarkdownBlock')]
(r / "TapRegression.swift").write_text(fixture + support + editor + component)
(r / "TapTests.swift").write_text('import XCTest\nfinal class TapTests: XCTestCase {\n func testPrefillCancelAndSave() {\n  let app = XCUIApplication(); app.launch(); app.buttons["编辑"].tap()\n  let title = app.textFields.firstMatch\n  XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "Original")\n  XCTAssertEqual(app.textViews.firstMatch.value as? String, "first\\nlast\\n")\n  XCTAssertEqual(app.switches["测试标签"].value as? String, "1")\n  app.buttons["取消"].tap(); XCTAssertTrue(app.staticTexts["Saved: Original"].waitForExistence(timeout: 5))\n  app.buttons["编辑"].tap(); title.tap(); title.typeText("X")\n  let draft = title.value as! String; XCTAssertNotEqual(draft, "Original")\n  app.buttons["保存修改"].tap()\n  XCTAssertTrue(app.staticTexts["Saved: \(draft)"].waitForExistence(timeout: 5))\n }\n func testErrorKeepsDraft() {\n  let app = XCUIApplication(); app.launch(); app.buttons["错误测试"].tap()\n  let title = app.textFields.firstMatch; XCTAssertTrue(title.waitForExistence(timeout: 5))\n  title.tap(); title.typeText("X"); let draft = title.value as! String; app.buttons["保存修改"].tap()\n  XCTAssertTrue(app.staticTexts["保存失败测试"].waitForExistence(timeout: 5))\n  app.buttons["关闭"].tap(); XCTAssertEqual(title.value as? String, draft)\n  XCTAssertTrue(app.buttons["保存修改"].isEnabled)\n }\n}\n')
tests = (r / "TapTests.swift").read_text()
extra = r"""
 func testPreviewSpoilerAndHelp() {
  let app = XCUIApplication(); app.launch(); app.buttons["编辑"].tap()
  let editor = app.textViews.firstMatch
  app.swipeUp(); XCTAssertTrue(editor.waitForExistence(timeout: 5))
  app.buttons["剧透"].tap()
  let draft = editor.value as! String
  XCTAssertTrue(draft.contains("!!剧透内容!!")); XCTAssertFalse(draft.contains("!!!!"))
  app.buttons["预览"].tap(); XCTAssertTrue(app.staticTexts[draft].waitForExistence(timeout: 5))
  app.buttons["编辑"].tap(); XCTAssertEqual(editor.value as? String, draft)
  app.buttons["Markdown 语法帮助"].tap()
  XCTAssertTrue(app.navigationBars["Markdown 语法帮助"].waitForExistence(timeout: 5))
  app.buttons["完成"].tap(); XCTAssertEqual(editor.value as? String, draft)
 }
"""
tests = tests.replace('final class TapTests: XCTestCase {', 'final class TapTests: XCTestCase {\n func reveal(_ element: XCUIElement, _ app: XCUIApplication) { for _ in 0..<8 { if element.exists && element.isHittable && element.frame.minY > 100 && element.frame.maxY < app.frame.maxY - 90 { return }; if element.exists && element.frame.minY < 100 { app.swipeDown() } else { app.swipeUp() } } }\n func dismissKeyboard(_ app: XCUIApplication) { if app.keyboards.count > 0 && app.buttons["完成"].firstMatch.exists { app.buttons["完成"].firstMatch.tap() } }')
tests = tests.replace('XCTAssertEqual(app.textViews.firstMatch.value', 'reveal(app.textViews.firstMatch, app); XCTAssertEqual(app.textViews.firstMatch.value')
tests = tests.replace('title.tap(); title.typeText("X")', 'reveal(title, app); title.tap(); title.typeText("X")')
tests = tests.replace('app.buttons["保存修改"].tap()', 'dismissKeyboard(app); reveal(app.buttons["保存修改"], app); app.buttons["保存修改"].tap()')
tests = tests.replace('app.buttons["关闭"].tap(); XCTAssertEqual(title.value as? String, draft)', 'app.buttons["关闭"].tap(); reveal(title, app); XCTAssertEqual(title.value as? String, draft)')
tests = tests.replace('XCTAssertTrue(app.buttons["保存修改"].isEnabled)', 'reveal(app.buttons["保存修改"], app); XCTAssertTrue(app.buttons["保存修改"].isEnabled)')
extra = extra.replace('app.swipeUp(); XCTAssertTrue(editor.waitForExistence(timeout: 5))', 'reveal(editor, app); XCTAssertTrue(editor.exists)').replace('app.buttons["剧透"].tap()', 'reveal(app.buttons["粗体"], app); app.buttons["粗体"].swipeLeft(); app.buttons["剧透"].tap()').replace('app.buttons["预览"].tap()', 'dismissKeyboard(app); app.buttons["预览"].tap()').replace('app.buttons["Markdown 语法帮助"].tap()', 'reveal(app.buttons["Markdown 语法帮助"], app); app.buttons["Markdown 语法帮助"].tap()')
extra += r"""
 func testNoticeCategoriesAndDraftReturn() {
  let app = XCUIApplication(); app.launch(); app.buttons["编辑"].tap()
  let link = app.links["站务公告"]
  XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
  XCTAssertTrue(app.staticTexts["分类: announcements 搜索: "].waitForExistence(timeout: 5))
  app.navigationBars["分类页面"].buttons.firstMatch.tap()
  let title = app.textFields["forum-post-title"]
  XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "Original")
  let feedback = app.links["意见反馈"]; XCTAssertTrue(feedback.exists); feedback.tap()
  XCTAssertTrue(app.staticTexts["分类: feedback 搜索: "].waitForExistence(timeout: 5))
  app.navigationBars["分类页面"].buttons.firstMatch.tap()
  app.links["求书集中帖"].tap()
  XCTAssertTrue(app.staticTexts["分类: novel 搜索: 求书集中贴"].waitForExistence(timeout: 5))
 }
"""
tests = tests.rsplit('}', 1)[0] + extra + '}\n'
tests = tests.replace('app.textFields.firstMatch', 'app.textFields["forum-post-title"]').replace('app.buttons["预览"]', 'app.segmentedControls.buttons["预览"]').replace('app.buttons["编辑"].tap(); XCTAssertEqual(editor', 'app.segmentedControls.buttons["编辑"].tap(); XCTAssertEqual(editor')

tests = tests.replace('app.swipeUp()', 'app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2)))').replace('app.swipeDown()', 'app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8)))')


(r / "TapTests.swift").write_text(tests)
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
for n,extra in [(30,''),(31,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.spoiler-tap-regression"; INFOPLIST_KEY_UILaunchScreen_Generation=YES;'),(32,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.spoiler-tap-regression.tests"; TEST_TARGET_NAME=TapRegression;')]:obj(n,'isa=XCBuildConfiguration; name=Debug; buildSettings={'+settings+extra+'};')
for n,c in [(20,30),(21,31),(22,32)]:obj(n,f'isa=XCConfigurationList; buildConfigurations=({ID(c)}); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
p=r/'TapRegression.xcodeproj';p.mkdir(exist_ok=True);(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={'+''.join(objects)+'}; rootObject='+ID(1)+';}')
d=p/'xcshareddata/xcschemes';d.mkdir(parents=True,exist_ok=True)
def ref(n,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ID(n)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:TapRegression.xcodeproj"/>'
(d/'TapTests.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction parallelizeBuildables="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">'+ref(10,'TapRegression.app')+'</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">'+ref(11,'TapTests.xctest')+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+ref(11,'TapTests.xctest')+'</TestableReference></Testables></TestAction></Scheme>')
print(f'UI test artifacts: {r}', flush=True)
with (r / 'test.log').open('w') as log:
 subprocess.run(['xcodebuild','-project',str(p),'-scheme','TapTests','-destination',f'platform=iOS Simulator,id={args.device}','-derivedDataPath',str(r/'DerivedData'),'-parallel-testing-enabled','NO','test'],stdout=log,stderr=subprocess.STDOUT,check=True)
print('Forum post editor prefill/cancel/save/error UI regressions passed')
