import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WebKit

private enum EPUBReadingLayout: String, CaseIterable, Identifiable, Codable {
    case paged, chapterScroll
    var id: String { rawValue }
    var title: String { self == .paged ? "分页阅读" : "章节内滚动" }
}

private enum EPUBTurnAnimation: String, CaseIterable, Identifiable, Codable {
    case simulation, slide, cover, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simulation: "仿真翻页"
        case .slide: "平移"
        case .cover: "覆盖"
        case .none: "无动画"
        }
    }
}

private struct EPUBReaderPreferences: Codable, Equatable {
    var paragraphSpacing = 0.4
    var lineHeight = 1.5
    var fontFamily = "serif"
    var fontSize = 1.15
    var backgroundHex = "F8F3E9"
    var backgroundImagePath: String?
    var verticalText = false
    var readingDirection = "ltr"
    var publisherStyles = false
    var volumeButtonsTurnPages = false
    var layout: EPUBReadingLayout = .paged
    var animation: EPUBTurnAnimation = .slide

    var readium: EPUBPreferences {
        EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: backgroundHex),
            fontFamily: ReadiumNavigator.FontFamily(rawValue: fontFamily),
            fontSize: fontSize,
            lineHeight: lineHeight,
            paragraphSpacing: paragraphSpacing,
            publisherStyles: publisherStyles,
            readingProgression: ReadiumNavigator.ReadingProgression(rawValue: readingDirection),
            scroll: layout == .chapterScroll,
            verticalText: verticalText
        )
    }

    var backgroundImageData: Data? {
        guard let backgroundImagePath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: backgroundImagePath))
    }
}

@MainActor
private final class EPUBReaderPreferencesStore: ObservableObject {
    static let shared = EPUBReaderPreferencesStore()
    @Published var value: EPUBReaderPreferences {
        didSet { persist() }
    }

    private let key = "wenku.epub.reader.preferences.v1"
    private let fileManager = FileManager.default

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let value = try? JSONDecoder().decode(EPUBReaderPreferences.self, from: data) {
            self.value = value
        } else {
            value = EPUBReaderPreferences()
        }
    }

    func importBackgroundImage(from source: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var coordinatedError: NSError?
        var imageData: Data?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatedError) { url in
            imageData = try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        if let coordinatedError { throw coordinatedError }
        guard let imageData, let image = UIImage(data: imageData),
              let normalized = image.jpegData(compressionQuality: 0.86) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WenkuEPUB", isDirectory: true)
            .appendingPathComponent("Reader", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let destination = support.appendingPathComponent("background.jpg")
        try normalized.write(to: destination, options: .atomic)
        value.backgroundImagePath = destination.path
    }

    func removeBackgroundImage() {
        if let path = value.backgroundImagePath { try? fileManager.removeItem(atPath: path) }
        value.backgroundImagePath = nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
private final class WenkuEPUBReaderModel: ObservableObject, EPUBNavigatorDelegate {
    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var publication: Publication?
    @Published private(set) var tableOfContents: [WenkuEPUBTOCEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentHref: String?
    @Published private(set) var totalProgression: Double?
    private var positionCount: Int?
    private var onLocationChanged: ((Locator) -> Void)?
    private var onTap: (() -> Void)?
    private var backgroundImageBase64: String?

    func open(
        _ url: URL,
        initialLocatorJSON: String?,
        preferences: EPUBReaderPreferences,
        onTap: @escaping () -> Void,
        onLocationChanged: @escaping (Locator) -> Void
    ) async {
        errorMessage = nil
        self.onLocationChanged = onLocationChanged
        self.onTap = onTap
        backgroundImageBase64 = preferences.backgroundImageData?.base64EncodedString()
        do {
            let httpClient = DefaultHTTPClient()
            let assetRetriever = AssetRetriever(httpClient: httpClient)
            let opener = PublicationOpener(
                parser: DefaultPublicationParser(
                    httpClient: httpClient,
                    assetRetriever: assetRetriever,
                    pdfFactory: DefaultPDFDocumentFactory()
                )
            )
            guard let fileURL = FileURL(url: url) else {
                throw WenkuEPUBReaderError.invalidURL
            }
            let asset = try await assetRetriever.retrieve(url: fileURL).get()
            let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
            guard publication.conforms(to: .epub) else {
                throw WenkuEPUBReaderError.unsupportedPublication
            }
            let initialLocation: Locator? = {
                guard let initialLocatorJSON,
                      let json = try? JSONValue(jsonString: initialLocatorJSON) else { return nil }
                return try? Locator(json: json, warnings: nil)
            }()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: EPUBNavigatorViewController.Configuration(preferences: preferences.readium)
            )
            navigator.delegate = self
            navigator.view.backgroundColor = ReadiumNavigator.Color(hex: preferences.backgroundHex)?.uiColor ?? .systemBackground
            navigator.view.isOpaque = false
            self.publication = publication
            self.navigator = navigator
            let toc = (try? await publication.tableOfContents().get()) ?? publication.readingOrder
            tableOfContents = Self.flatten(toc)
            positionCount = try? await publication.positions().get().count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func go(to link: ReadiumShared.Link) async {
        guard let navigator else { return }
        _ = await navigator.go(to: link, options: .animated)
    }

    func apply(_ preferences: EPUBReaderPreferences) async {
        guard let navigator else { return }
        backgroundImageBase64 = preferences.backgroundImageData?.base64EncodedString()
        navigator.submitPreferences(preferences.readium)
        navigator.view.backgroundColor = ReadiumNavigator.Color(hex: preferences.backgroundHex)?.uiColor ?? .systemBackground
        navigator.view.isOpaque = false
        let imageScript = Self.backgroundImageScript(base64: backgroundImageBase64)
        _ = await navigator.evaluateJavaScript(imageScript)
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        currentHref = locator.href.string
        if let total = locator.locations.totalProgression {
            totalProgression = total
        } else if let position = locator.locations.position, let positionCount, positionCount > 0 {
            totalProgression = min(1, max(0, Double(position) / Double(positionCount)))
        } else {
            totalProgression = nil
        }
        onLocationChanged?(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = "EPUB 阅读器发生错误：\(error)"
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard let epubNavigator = self.navigator else { return }
        let bounds = epubNavigator.view.bounds
        guard bounds.width > 0, bounds.height > 0,
              (0.28 ... 0.72).contains(point.x / bounds.width),
              (0.25 ... 0.75).contains(point.y / bounds.height) else { return }
        onTap?()
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(
            source: Self.backgroundImageScript(base64: backgroundImageBase64),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
    }

    private static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [WenkuEPUBTOCEntry] {
        links.flatMap { link in
            [WenkuEPUBTOCEntry(id: "\(depth)-\(link.href)", link: link, depth: depth)]
                + flatten(link.children, depth: depth + 1)
        }
    }

    private static func backgroundImageScript(base64: String?) -> String {
        let background = base64.map { "url(data:image/jpeg;base64,\($0))" } ?? "none"
        return """
        (() => {
          const apply = () => {
            let style = document.getElementById('novelia-reader-custom-background');
            if (!style) {
              style = document.createElement('style');
              style.id = 'novelia-reader-custom-background';
              (document.head || document.documentElement).appendChild(style);
            }
            const css = 'html, body { background-image: \(background) !important; background-size: cover !important; background-position: center !important; background-attachment: fixed !important; background-color: transparent !important; }';
            if (style.textContent !== css) style.textContent = css;
          };
          apply();
          new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
    }
}

private struct WenkuEPUBTOCEntry: Identifiable {
    let id: String
    let link: ReadiumShared.Link
    let depth: Int
}

struct WenkuEPUBReaderView: View {
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: LocalWenkuEPUB
    let url: URL

    @StateObject private var model = WenkuEPUBReaderModel()
    @StateObject private var preferences = EPUBReaderPreferencesStore.shared
    @State private var isShowingTOC = false
    @State private var isShowingSettings = false
    @State private var isShowingControls = true

    var body: some View {
        Group {
            if let navigator = model.navigator {
                ReadiumNavigatorContainer(navigator: navigator)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = model.errorMessage {
                ContentUnavailableView("无法打开 EPUB", systemImage: "book.closed", description: Text(error))
            } else {
                ProgressView("正在解析 EPUB…")
            }
        }
        .navigationTitle(model.publication?.metadata.title ?? book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isShowingControls ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.navigator != nil && isShowingControls {
                HStack(spacing: 14) {
                    Button { Task { await turnPage(forward: false) } } label: {
                        Image(systemName: "chevron.left").frame(width: 36, height: 34)
                    }
                    .accessibilityLabel("上一页")
                    ProgressView(value: model.totalProgression ?? 0)
                        .tint(NoveliaStyle.coral)
                    Text(model.totalProgression.map { "全书 \(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NoveliaStyle.muted)
                        .monospacedDigit()
                    Button { Task { await turnPage(forward: true) } } label: {
                        Image(systemName: "chevron.right").frame(width: 36, height: 34)
                    }
                    .accessibilityLabel("下一页")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(.regularMaterial)
            }
        }
        .background(alignment: .topLeading) {
            VolumeButtonHandler(isEnabled: preferences.value.volumeButtonsTurnPages) { isVolumeUp in
                Task { await turnPage(forward: isVolumeUp) }
            }
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { isShowingTOC = true } label: { Label("目录", systemImage: "list.bullet") }
                        .disabled(model.navigator == nil || model.tableOfContents.isEmpty)
                    Button { isShowingSettings = true } label: { Label("阅读设置", systemImage: "textformat.size") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("阅读菜单")
                .sheet(isPresented: $isShowingSettings) {
                    EPUBReaderSettingsView(store: preferences)
                }
            }
        }
        .sheet(isPresented: $isShowingTOC) {
            NavigationStack {
                List(model.tableOfContents) { entry in
                    let isCurrent = Self.isCurrent(entry.link.href, locatorHref: model.currentHref)
                    Button {
                        Task {
                            await model.go(to: entry.link)
                            isShowingTOC = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.link.title ?? entry.link.href)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(entry.depth) * 14)
                                .foregroundStyle(isCurrent ? NoveliaStyle.coral : NoveliaStyle.ink)
                            Spacer(minLength: 4)
                            if isCurrent {
                                Text("当前")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(NoveliaStyle.coral)
                            }
                        }
                    }
                    .listRowBackground(isCurrent ? NoveliaStyle.coral.opacity(0.08) : Color.clear)
                }
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { isShowingTOC = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: url) {
            await model.open(
                url,
                initialLocatorJSON: book.lastLocatorJSON,
                preferences: preferences.value,
                onTap: { isShowingControls.toggle() }
            ) { locator in
                    guard let json = try? locator.jsonString() else { return }
                    localLibrary.updateReadingLocation(bookID: book.id, locatorJSON: json)
                }
        }
        .onChange(of: preferences.value) { _, newValue in
            Task { await model.apply(newValue) }
        }
    }

    @MainActor
    private func turnPage(forward: Bool) async {
        guard let navigator = model.navigator else { return }
        let move = { @MainActor in
            if forward { _ = await navigator.goForward(options: .none) }
            else { _ = await navigator.goBackward(options: .none) }
        }
        switch preferences.value.animation {
        case .none:
            await move()
        case .slide:
            if forward { _ = await navigator.goForward(options: .animated) }
            else { _ = await navigator.goBackward(options: .animated) }
        case .simulation, .cover:
            let transition: UIView.AnimationOptions = preferences.value.animation == .simulation
                ? (forward ? .transitionCurlUp : .transitionCurlDown)
                : (forward ? .transitionFlipFromRight : .transitionFlipFromLeft)
            await withCheckedContinuation { continuation in
                UIView.transition(with: navigator.view, duration: 0.45, options: [transition, .showHideTransitionViews]) {
                    Task { @MainActor in
                        await move()
                        continuation.resume()
                    }
                }
            }
        }
    }

    private static func isCurrent(_ href: String, locatorHref: String?) -> Bool {
        guard let locatorHref else { return false }
        func resourcePath(_ value: String) -> String {
            let withoutFragment = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
            return URL(string: withoutFragment)?.lastPathComponent ?? withoutFragment
        }
        return resourcePath(href) == resourcePath(locatorHref)
    }
}

private struct EPUBReaderSettingsView: View {
    @ObservedObject var store: EPUBReaderPreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingBackground = false
    @State private var errorMessage: String?

    private let fontFamilies: [(String, String)] = [
        ("serif", "衬线"),
        ("sans-serif", "无衬线"),
        ("Iowan Old Style", "Iowan Old Style"),
        ("Palatino", "Palatino"),
        ("Georgia", "Georgia"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("OpenDyslexic", "OpenDyslexic 易读字体"),
        ("monospace", "等宽字体"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("文字排版") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(store.value.fontSize * 100))%")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: binding(\.fontSize), in: 0.7 ... 2.5, step: 0.05)
                    }
                    Picker("字体", selection: binding(\.fontFamily)) {
                        ForEach(fontFamilies, id: \.0) { value, title in Text(title).tag(value) }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("行间距")
                            Spacer()
                            Text(String(format: "%.1f", store.value.lineHeight)).foregroundStyle(.secondary)
                        }
                        Slider(value: binding(\.lineHeight), in: 1.0 ... 2.0, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("段落间距")
                            Spacer()
                            Text("\(Int(store.value.paragraphSpacing * 100))% 字号")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: binding(\.paragraphSpacing), in: 0 ... 2.0, step: 0.1)
                    }
                    Toggle("使用书籍内置样式", isOn: binding(\.publisherStyles))
                    if store.value.publisherStyles {
                        Text("启用书籍样式时，书籍自身的排版可能覆盖字体、间距和颜色设置。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("阅读外观") {
                    ColorPicker("背景颜色", selection: Binding(
                        get: { ReadiumNavigator.Color(hex: store.value.backgroundHex)?.color ?? .white },
                        set: { newColor in
                            if let color = ReadiumNavigator.Color(color: newColor) {
                                store.value.backgroundHex = String(format: "%06X", color.rawValue & 0xFFFFFF)
                            }
                        }
                    ), supportsOpacity: false)
                    HStack {
                        Label(store.value.backgroundImagePath == nil ? "背景图片" : "已设置背景图片", systemImage: "photo")
                        Spacer()
                        if store.value.backgroundImagePath != nil {
                            Button("移除", role: .destructive) { store.removeBackgroundImage() }
                        }
                        Button("选择") { isImportingBackground = true }
                    }
                    Toggle("竖排文字", isOn: binding(\.verticalText))
                    Picker("阅读方向", selection: binding(\.readingDirection)) {
                        Text("从左到右").tag("ltr")
                        Text("从右到左").tag("rtl")
                    }
                    Picker("阅读方式", selection: binding(\.layout)) {
                        ForEach(EPUBReadingLayout.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    if store.value.verticalText && store.value.layout == .chapterScroll {
                        Text("竖排阅读由 Readium 使用分页布局；关闭竖排后可使用章节内滚动。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("翻页") {
                    Toggle("音量键翻页", isOn: binding(\.volumeButtonsTurnPages))
                    Picker("翻页动画", selection: binding(\.animation)) {
                        ForEach(EPUBTurnAnimation.allCases) { animation in Text(animation.title).tag(animation) }
                    }
                    Text("底部上一页/下一页按钮和音量键支持所选动画；直接滑动翻页仍由 Readium 的页面手势处理。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .fileImporter(isPresented: $isImportingBackground, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try store.importBackgroundImage(from: url)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("无法设置背景图片", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EPUBReaderPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { store.value[keyPath: keyPath] = $0 }
        )
    }
}

private struct VolumeButtonHandler: UIViewRepresentable {
    let isEnabled: Bool
    let onVolumeChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        context.coordinator.update(view: view, enabled: isEnabled, onChange: onVolumeChange)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        context.coordinator.update(view: uiView, enabled: isEnabled, onChange: onVolumeChange)
    }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var observation: NSKeyValueObservation?
        private weak var volumeView: MPVolumeView?
        private var onChange: ((Bool) -> Void)?
        private var lastVolume: Float?
        private var isEnabled = false
        private var isRestoringVolume = false

        func update(view: MPVolumeView, enabled: Bool, onChange: @escaping (Bool) -> Void) {
            volumeView = view
            self.onChange = onChange
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            observation = nil
            guard enabled else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            lastVolume = AVAudioSession.sharedInstance().outputVolume
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let current = change.newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isRestoringVolume,
                          let previous = self.lastVolume, current != previous else { return }
                    self.restoreVolume(to: previous, changedTo: current)
                }
            }
        }

        func stop() {
            observation = nil
            isEnabled = false
        }

        private func restoreVolume(to previous: Float, changedTo current: Float) {
            guard isEnabled else { return }
            lastVolume = current
            onChange?(current > previous)
            isRestoringVolume = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.isEnabled else { return }
                guard let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
                    self.isRestoringVolume = false
                    self.lastVolume = AVAudioSession.sharedInstance().outputVolume
                    return
                }
                slider.value = previous
                slider.sendActions(for: .valueChanged)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.isRestoringVolume = false
                    self.lastVolume = AVAudioSession.sharedInstance().outputVolume
                }
            }
        }
    }
}

private struct ReadiumNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}

private enum WenkuEPUBReaderError: LocalizedError {
    case invalidURL
    case unsupportedPublication

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无法读取本地 EPUB 文件路径。"
        case .unsupportedPublication: "该文件不是 Readium 支持的 EPUB。"
        }
    }
}
