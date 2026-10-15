#!/usr/bin/env python3
"""Requires Xcode and a booted iOS simulator; uses no account or network data."""
from pathlib import Path
import subprocess
import argparse
import tempfile

parser = argparse.ArgumentParser(description="Run production forum table layout and spoiler link interaction checks in a simulator.")
parser.add_argument("--device", required=True, help="Booted iOS simulator UDID")
args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix="NoveliaSpoilerTapRegression-"))
source = Path(__file__).resolve().parents[1] / "iOSApp/Features/Community/ForumListView.swift"
markdown = (source.parent / "ForumMarkdownViews.swift").read_text()
s = source.read_text()
core = (Path(__file__).resolve().parents[1] / "Sources/NoveliaIOSCore/Features/Community/ForumMarkdown.swift").read_text()
wenku = (Path(__file__).resolve().parents[1] / "Sources/NoveliaIOSCore/Domain/WenkuNovel.swift").read_text()
tail = r"""@main struct TapRegressionApp: App {
 var body: some Scene { WindowGroup { TestScreen() } }
}
struct TestScreen: View {
 @State private var opened = 0
 @State private var allPosts = true
 @State private var category = "announcements"
 var body: some View {
  VStack(spacing: 30) {
    ForumCategoryBar(categories: [ForumCategory(id: 1, title: "站务公告", slug: "announcements"), ForumCategory(id: 2, title: "小说讨论", slug: "novel"), ForumCategory(id: 3, title: "意见反馈", slug: "feedback")], selectedCategory: category, isVisible: allPosts) { category = $0.slug }
   ForumMarkdownTable(rows: [["第一列", "第二列", "第三列"], [String(repeating: "长文本应当完整换行显示，不允许省略。", count: 8), "中间内容", "末列内容"]], mode: .article)
    .font(.system(size: 15)).frame(height: 300)
   Button(allPosts ? "云端收藏" : "全部帖子") { allPosts.toggle() }
   Text("当前分类: \(category)")
   Text("Spoiler tap regression").font(.title)
   ForumInlineMarkdownText(markdown: "`!!示例!!` 正文 !![测试链接](https://n.novelia.cc/novel/hameln/test)!!")
    .textSelection(.enabled)
    .environment(\.openURL, OpenURLAction { _ in opened += 1; return .handled })
   Text("Opened: \(opened)").accessibilityIdentifier("opened-count")
  }.padding(.horizontal, 12).padding(.vertical, 20)

 }
}
"""
code='import SwiftUI\nimport UIKit\nimport Foundation\nprivate enum NoveliaStyle { static let ink = Color.primary; static let brandGreen = Color.green; static let paper = Color.white; static let card = Color.white; static let muted = Color.gray }\nprivate struct ForumCategory: Identifiable { let id: Int; let title: String; let slug: String }\n'+s[s.index('private struct ForumCategoryBar'):s.index('struct ForumErrorOverlay')]+markdown[markdown.index('private struct ForumMarkdownTable'):markdown.index('private struct ForumStarRating')]+core[core.index('struct ForumPostRoute: Identifiable'):]+wenku[:wenku.index('public struct WenkuNovelDetail')]+tail
code = code.replace('import SwiftUI\n', 'import SwiftUI\n' + (Path(__file__).resolve().parents[1]/'Sources/NoveliaIOSCore/Infrastructure/API/APIConfiguration.swift').read_text(), 1)
(r/'TapRegression.swift').write_text(code)
(r/'TapTests.swift').write_text('''import XCTest
final class TapTests: XCTestCase {
 func testCategoriesReturnAfterFavorites() {
  let app = XCUIApplication(); app.launch()
  for _ in 0..<3 {
   XCTAssertTrue(app.buttons["站务公告"].waitForExistence(timeout: 5))
   app.buttons["云端收藏"].tap()
   XCTAssertFalse(app.buttons["站务公告"].exists)
   app.buttons["全部帖子"].tap()
   XCTAssertTrue(app.buttons["小说讨论"].waitForExistence(timeout: 5))
   XCTAssertTrue(app.buttons["意见反馈"].isHittable)
  }
  app.buttons["小说讨论"].tap()
  XCTAssertTrue(app.staticTexts["当前分类: novel"].exists)
 }
 func testTableWrapsAndScrolls() {
  let app = XCUIApplication()
  app.launch()
  let cell = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "长文本应当完整换行显示")).firstMatch
  XCTAssertTrue(cell.waitForExistence(timeout: 10))
  XCTAssertGreaterThan(cell.frame.height, 100)
  XCTAssertLessThanOrEqual(cell.frame.width, 221)
  let first = app.otherElements["forum-table-cell-1-0"].firstMatch
  let second = app.otherElements["forum-table-cell-1-1"].firstMatch
  XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
  XCTAssertEqual(first.frame.maxY, second.frame.maxY, accuracy: 1)
  XCTAssertGreaterThan(first.frame.height, 100)
  let header = app.staticTexts["第一列"]
  XCTAssertTrue(header.isHittable)
  let viewport = app.scrollViews["forum-markdown-table"].frame
  XCTAssertGreaterThanOrEqual(header.frame.minY, viewport.minY)
  XCTAssertLessThanOrEqual(header.frame.maxY, viewport.maxY)
  let headerCell = app.otherElements["forum-table-cell-0-0"].firstMatch
  XCTAssertGreaterThanOrEqual(header.frame.minY, headerCell.frame.minY)
  XCTAssertLessThanOrEqual(header.frame.maxY, headerCell.frame.maxY)
  app.scrollViews["forum-markdown-table"].swipeLeft()
  XCTAssertTrue(app.staticTexts["末列内容"].isHittable)
 }
 func testRevealThenTapLink() {
  let app = XCUIApplication()
  app.launch()
  let concealed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "测试链接")).firstMatch
  XCTAssertTrue(concealed.waitForExistence(timeout: 10))
  concealed.tap()
  let link = app.links["测试链接"]
  XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
  link.tap()
  XCTAssertTrue(app.staticTexts["Opened: 1"].waitForExistence(timeout: 5), app.debugDescription)
 }
}
''')
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
print('Forum categories, table alignment/scrolling and spoiler link UI regressions passed')
