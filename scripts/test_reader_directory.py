#!/usr/bin/env python3
"""在 iOS 模拟器中用合成章节测试生产代码的在线章节目录。"""
from pathlib import Path
import argparse
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix="NoveliaDirectoryRegression-"))
s = (Path(__file__).resolve().parents[1] / "iOSApp/Features/Reader/ReaderView.swift").read_text()
component = s[s.index("private struct ChapterDirectoryView"):s.index("private struct Paragraphs")]
fixture = 'import SwiftUI\nprivate enum NoveliaStyle { static let brandGreen = Color.green }\nprivate enum ReaderAppearance {\n case system\n func secondaryText(system: ColorScheme) -> Color { .secondary }\n func primaryText(system: ColorScheme) -> Color { .primary }\n func card(system: ColorScheme) -> Color { Color(uiColor: .secondarySystemBackground) }\n func background(system: ColorScheme) -> Color { Color(uiColor: .systemBackground) }\n}\nprivate struct Chapter { let id: String; let title: String }\nprivate struct Novel { let chapters: [Chapter] }\n@main struct TapRegressionApp: App {\n var body: some Scene { WindowGroup { TestScreen() } }\n}\nprivate struct TestScreen: View {\n @State private var selected = 400\n let novel = Novel(chapters: (0..<600).map { Chapter(id: "chapter-\\($0)", title: "第\\($0 + 1)章") })\n var body: some View {\n  NavigationStack {\n   VStack {\n    Text("Current: \\(selected + 1)")\n    Button("First") { selected = 0 }\n    Button("Last") { selected = 599 }\n    NavigationLink("目录") { ChapterDirectoryView(novel: novel, selectedIndex: $selected, appearance: .system) }\n   }\n  }\n }\n}\n'
(r / "TapRegression.swift").write_text(fixture + component)
(r / "TapTests.swift").write_text('import XCTest\nfinal class TapTests: XCTestCase {\n func testCurrentChapterAndReopening() {\n  let app = XCUIApplication(); app.launch()\n  app.buttons["目录"].tap()\n  let current = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "第401章")).firstMatch\n  XCTAssertTrue(current.waitForExistence(timeout: 5)); XCTAssertTrue(current.isHittable)\n  let next = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "第402章")).firstMatch\n  next.tap()\n  XCTAssertTrue(app.staticTexts["Current: 402"].waitForExistence(timeout: 5))\n  app.buttons["目录"].tap()\n  XCTAssertTrue(next.waitForExistence(timeout: 5)); XCTAssertTrue(next.isHittable)\n }\n func testFirstAndLastChapter() {\n  let app = XCUIApplication(); app.launch()\n  for (control, title) in [("First", "第1章"), ("Last", "第600章")] {\n   app.buttons[control].tap(); app.buttons["目录"].tap()\n   let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch\n   XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.isHittable)\n   row.tap()\n  }\n }\n}\n')
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
print('Online reader directory auto-position UI regressions passed')
