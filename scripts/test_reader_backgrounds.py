#!/usr/bin/env python3
"""在 iOS 模拟器上检查生产代码的阅读背景存储。"""
import argparse
import subprocess
import tempfile
from pathlib import Path
parser = argparse.ArgumentParser(); parser.add_argument('--device', required=True); args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix='NoveliaBackgroundChecks-'))
source = (Path(__file__).resolve().parents[1]/'iOSApp/App/NoveliaApp.swift').read_text()
code = 'import SwiftUI\nimport UIKit\nimport ImageIO\nimport CryptoKit\n'
code += 'enum FileContentHash { static func sha256(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() } }\n'
code += source[source.index('enum AppThemeColor:'):source.index('enum NoveliaStyle')]
background = (Path(__file__).resolve().parents[1]/'iOSApp/Features/Reader/ReaderBackground.swift').read_text()
code += background[background.index('@MainActor\nfinal class ReaderBackgroundStore:'):background.index('struct ReaderBackgroundView:')]
sync = (Path(__file__).resolve().parents[1]/'Sources/NoveliaIOSCore/Features/Sync/SyncMerge.swift').read_text()
code += sync[sync.index('struct SyncedReaderBackground:'):sync.index('struct SyncedImportedFont:')]
code += background[background.index('@MainActor\nextension ReaderBackgroundStore'):]
code += r'''
@main struct TapRegressionApp: App {
 var body: some Scene { WindowGroup { CheckView() } }
}
struct CheckView: View {
 @State private var result = "Checking"
 var body: some View { Text(result).task { runChecks() } }
 @MainActor func runChecks() {
  let name = "BackgroundChecks-\(UUID())"; let defaults = UserDefaults(suiteName: name)!
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
  let store = ReaderBackgroundStore(defaults: defaults, directory: directory)
  precondition(store.mode(dark: false) == "default" && store.mode(dark: true) == "default")
  store.setColor(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1), dark: false); store.setColor(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1), dark: true)
  precondition(store.hex(dark: false) == "FF0000" && store.hex(dark: true) == "0000FF")
  let image = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1600)).image { context in UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600)) }
  do {
   try store.importImage(image.pngData()!, dark: false)
   precondition(store.image(dark: false)!.size.width <= 2048 && store.image(dark: true) == nil)
   let restored = ReaderBackgroundStore(defaults: defaults, directory: directory)
   precondition(restored.mode(dark: false) == "image" && restored.image(dark: false) != nil && restored.hex(dark: true) == "0000FF")
   do { try store.importImage(Data("invalid".utf8), dark: false); preconditionFailure("invalid image accepted") } catch {}
   precondition(store.mode(dark: false) == "image")
   try store.importImage(image.pngData()!, dark: false, landscape: true)
   precondition(store.image(dark: false, landscape: true) != nil)
   let saved = try store.syncSnapshot(dark: false)
   precondition(saved.portraitHash != nil && saved.landscapeHash != nil)
   let other = ReaderBackgroundStore(defaults: UserDefaults(suiteName: name + "-remote")!, directory: directory.appendingPathComponent("remote"))
   defer { UserDefaults(suiteName: name + "-remote")!.removePersistentDomain(forName: name + "-remote") }
   try other.applySync(saved, dark: false, files: [saved.portraitHash!: store.imageURL(dark: false)])
   precondition(other.image(dark: false) != nil && other.image(dark: false, landscape: true) != nil)
   var removed = saved; removed.portraitHash = nil; removed.updatedAt = saved.updatedAt.addingTimeInterval(1)
   try other.applySync(removed, dark: false, files: [saved.landscapeHash!: store.imageURL(dark: false, landscape: true)])
   precondition(other.image(dark: false) == nil && other.image(dark: false, landscape: true) != nil)
   try other.applySync(saved, dark: false, files: [:])
   precondition(other.image(dark: false) == nil)
   try store.removeImage(dark: false)
   precondition(store.mode(dark: false) == "image" && store.image(dark: false) == nil && store.image(dark: false, landscape: true) != nil && store.mode(dark: true) == "color")
   store.restoreDefaultColor(dark: false)
   precondition(store.mode(dark: false) == "image" && store.hex(dark: false) == "FAF7F0" && store.image(dark: false, landscape: true) != nil)
   store.restoreDefaultColor(dark: true)
   precondition(store.mode(dark: true) == "default" && store.hex(dark: true) == "19191C")
   store.setColor(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1), dark: true)
   try store.restoreDefaults(dark: false)
   precondition(store.mode(dark: false) == "default" && store.hex(dark: false) == "FAF7F0")
   let reset = try store.syncSnapshot(dark: false)
   precondition(reset.portraitHash == nil && reset.landscapeHash == nil && reset.updatedAt > saved.updatedAt)
   precondition(store.mode(dark: true) == "color" && store.hex(dark: true) == "0000FF")
   result = "Background checks passed"
  } catch { result = error.localizedDescription }
 }
}
'''
(r/'TapRegression.swift').write_text(code)
(r/'TapTests.swift').write_text('''import XCTest
final class TapTests: XCTestCase {
 func testBackgroundStorage() { let app = XCUIApplication(); app.launch(); XCTAssertTrue(app.staticTexts["Background checks passed"].waitForExistence(timeout: 15)) }
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
print('Reader background color/image, mode separation, persistence and invalid image regressions passed')
