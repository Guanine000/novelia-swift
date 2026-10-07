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
    var firstLineIndent = 1.5
    var lineHeight = 1.5
    var fontFamily = "serif"
    var fontSize = 1.15
    var topMargin = 18.0
    var rightMargin = 20.0
    var bottomMargin = 18.0
    var leftMargin = 20.0
    var backgroundHex = "F8F3E9"
    var backgroundImagePath: String?
    var removeEmptyLines = false
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
            paragraphIndent: firstLineIndent,
            paragraphSpacing: paragraphSpacing,
            publisherStyles: publisherStyles,
            readingProgression: ReadiumNavigator.ReadingProgression(rawValue: readingDirection),
            // Readium forces scrolling with vertical text; paged mode below
            // uses viewport snapping on the EPUB's WKWebView scroll view.
            scroll: layout == .chapterScroll || verticalText,
            verticalText: verticalText
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paragraphSpacing, firstLineIndent, lineHeight, fontFamily, fontSize
        case topMargin, rightMargin, bottomMargin, leftMargin
        case backgroundHex, backgroundImagePath, removeEmptyLines
        case verticalText, readingDirection, publisherStyles, volumeButtonsTurnPages
        case layout, animation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paragraphSpacing = try values.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0.4
        firstLineIndent = try values.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? 1.5
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.5
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? "serif"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 1.15
        topMargin = try values.decodeIfPresent(Double.self, forKey: .topMargin) ?? 18
        rightMargin = try values.decodeIfPresent(Double.self, forKey: .rightMargin) ?? 20
        bottomMargin = try values.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? 18
        leftMargin = try values.decodeIfPresent(Double.self, forKey: .leftMargin) ?? 20
        backgroundHex = try values.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "F8F3E9"
        backgroundImagePath = try values.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        removeEmptyLines = try values.decodeIfPresent(Bool.self, forKey: .removeEmptyLines) ?? false
        verticalText = try values.decodeIfPresent(Bool.self, forKey: .verticalText) ?? false
        readingDirection = try values.decodeIfPresent(String.self, forKey: .readingDirection) ?? "ltr"
        publisherStyles = try values.decodeIfPresent(Bool.self, forKey: .publisherStyles) ?? false
        volumeButtonsTurnPages = try values.decodeIfPresent(Bool.self, forKey: .volumeButtonsTurnPages) ?? false
        layout = try values.decodeIfPresent(EPUBReadingLayout.self, forKey: .layout) ?? .paged
        animation = try values.decodeIfPresent(EPUBTurnAnimation.self, forKey: .animation) ?? .slide
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
private final class WenkuEPUBReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate, UIGestureRecognizerDelegate {
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
    private var activePreferences = EPUBReaderPreferences()
    private var onPageTurn: ((Bool) -> Void)?
    private var pageTurnPan: UIPanGestureRecognizer?

    func open(
        _ url: URL,
        initialLocatorJSON: String?,
        preferences: EPUBReaderPreferences,
        onTap: @escaping () -> Void,
        onPageTurn: @escaping (Bool) -> Void,
        onLocationChanged: @escaping (Locator) -> Void
    ) async {
        errorMessage = nil
        self.onLocationChanged = onLocationChanged
        self.onTap = onTap
        self.onPageTurn = onPageTurn
        activePreferences = preferences
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
            configureVerticalPaging(for: preferences)
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
        activePreferences = preferences
        backgroundImageBase64 = preferences.backgroundImageData?.base64EncodedString()
        navigator.submitPreferences(preferences.readium)
        navigator.view.backgroundColor = ReadiumNavigator.Color(hex: preferences.backgroundHex)?.uiColor ?? .systemBackground
        navigator.view.isOpaque = false
        _ = await navigator.evaluateJavaScript(Self.readerStyleScript(base64: backgroundImageBase64, preferences: preferences))
        configureVerticalPaging(for: preferences)
        for delay in [150_000_000, 500_000_000] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay))
                self?.configureVerticalPaging(for: preferences)
            }
        }
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
        configureVerticalPaging(for: EPUBReaderPreferencesStore.shared.value)
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
            source: Self.readerStyleScript(base64: backgroundImageBase64, preferences: activePreferences),
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

    private static func readerStyleScript(base64: String?, preferences: EPUBReaderPreferences) -> String {
        let background = base64.map { "url(data:image/jpeg;base64,\($0))" } ?? "none"
        let top = String(preferences.topMargin)
        let right = String(preferences.rightMargin)
        let bottom = String(preferences.bottomMargin)
        let left = String(preferences.leftMargin)
        let removeEmptyLines = preferences.removeEmptyLines ? "true" : "false"
        return """
        (() => {
          const apply = () => {
            let style = document.getElementById('novelia-reader-custom-background');
            if (!style) {
              style = document.createElement('style');
              style.id = 'novelia-reader-custom-background';
              (document.head || document.documentElement).appendChild(style);
            }
            const css = 'html, body { background-image: \(background) !important; background-size: cover !important; background-position: center !important; background-attachment: fixed !important; background-color: transparent !important; }' +
              ':root[style*="--USER__pageMargins"] body { padding: \(top)px \(right)px \(bottom)px \(left)px !important; }' +
              'body { padding: \(top)px \(right)px \(bottom)px \(left)px !important; }' +
              '.novelia-remove-empty-lines p.novelia-empty-line { display: none !important; }';
            if (style.textContent !== css) style.textContent = css;
            document.documentElement.classList.toggle('novelia-remove-empty-lines', \(removeEmptyLines));
            document.querySelectorAll('p').forEach(paragraph => {
              const hasMedia = paragraph.querySelector('img, svg, video, audio, canvas, iframe, object, embed, math');
              const isEmpty = !paragraph.textContent.replace(/[\\s\\u00a0\\u200b\\ufeff]/g, '') && !hasMedia;
              paragraph.classList.toggle('novelia-empty-line', isEmpty);
            });
          };
          apply();
          new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
    }

    private func configureVerticalPaging(for preferences: EPUBReaderPreferences) {
        guard let navigator else { return }
        let shouldSnapByViewport = preferences.layout == .paged
        let handlesPageGesture = shouldSnapByViewport &&
            (preferences.verticalText || preferences.animation != .slide)
        if pageTurnPan == nil {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pagePanEnded(_:)))
            pan.delegate = self
            navigator.view.addGestureRecognizer(pan)
            pageTurnPan = pan
        }
        pageTurnPan?.isEnabled = handlesPageGesture
        func update(_ view: UIView) {
            if let scrollView = view as? UIScrollView {
                scrollView.panGestureRecognizer.isEnabled = !handlesPageGesture
            }
            if let webView = view as? WKWebView {
                webView.scrollView.isPagingEnabled = shouldSnapByViewport
                webView.scrollView.decelerationRate = shouldSnapByViewport ? .fast : .normal
                webView.scrollView.bounces = !shouldSnapByViewport
            }
            view.subviews.forEach(update)
        }
        update(navigator.view)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func pagePanEnded(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let distance = pan.translation(in: pan.view).x
        let velocity = pan.velocity(in: pan.view).x
        guard abs(distance) > 35 || abs(velocity) > 250 else { return }
        let direction = abs(distance) > 35 ? distance : velocity
        let rtl = activePreferences.readingDirection == "rtl"
        onPageTurn?(rtl ? direction > 0 : direction < 0)
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
    @State private var isTurningPage = false

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
                        Image(systemName: pageArrow(forward: false)).frame(width: 36, height: 34)
                    }
                    .accessibilityLabel("上一页")
                    ProgressView(value: model.totalProgression ?? 0)
                        .tint(NoveliaStyle.coral)
                    Text(model.totalProgression.map { "全书 \(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NoveliaStyle.muted)
                        .monospacedDigit()
                    Button { Task { await turnPage(forward: true) } } label: {
                        Image(systemName: pageArrow(forward: true)).frame(width: 36, height: 34)
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
                onTap: { isShowingControls.toggle() },
                onPageTurn: { forward in Task { await turnPage(forward: forward) } }
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
        guard !isTurningPage, let navigator = model.navigator else { return }
        isTurningPage = true
        defer { isTurningPage = false }
        switch preferences.value.animation {
        case .none:
            _ = await advancePage(forward: forward, navigator: navigator, animated: false)
        case .slide:
            if preferences.value.verticalText && preferences.value.layout == .paged {
                await turnPageWithSnapshot(forward: forward, navigator: navigator)
            } else {
                _ = await advancePage(forward: forward, navigator: navigator, animated: true)
            }
        case .simulation, .cover:
            await turnPageWithSnapshot(forward: forward, navigator: navigator)
        }
    }

    @MainActor
    private func advancePage(
        forward: Bool,
        navigator: EPUBNavigatorViewController,
        animated: Bool
    ) async -> Bool {
        let prefs = preferences.value
        if prefs.verticalText && prefs.layout == .paged {
            let rtl = prefs.readingDirection == "rtl"
            let progression = forward ? 1 : -1
            let behavior = animated ? "smooth" : "instant"
            let script = """
            (() => {
              const root = document.scrollingElement || document.documentElement;
              const max = Math.max(0, root.scrollWidth - window.innerWidth);
              const current = Math.min(max, Math.abs(window.scrollX));
              const page = Math.round(current / window.innerWidth);
              const next = Math.max(0, Math.min(max, (page + \(progression)) * window.innerWidth));
              if (Math.abs(next - current) < 1) return false;
              const targetX = \(rtl ? "-next" : "next");
              window.scrollTo({ left: targetX, behavior: '\(behavior)' });
              return true;
            })()
            """
            if case let .success(value) = await navigator.evaluateJavaScript(script),
               (value as? Bool) == true {
                return true
            }
        }

        return forward
            ? await navigator.goForward(options: NavigatorGoOptions(animated: animated))
            : await navigator.goBackward(options: NavigatorGoOptions(animated: animated))
    }

    @MainActor
    private func turnPageWithSnapshot(forward: Bool, navigator: EPUBNavigatorViewController) async {
        guard let oldPage = navigator.view.snapshotView(afterScreenUpdates: false) else {
            _ = await advancePage(forward: forward, navigator: navigator, animated: false)
            return
        }
        // Keep the current page visible until the destination has finished drawing.
        // The animation owns a separate container and never changes Readium's views.
        let overlay = UIView(frame: navigator.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        oldPage.frame = overlay.bounds
        overlay.addSubview(oldPage)
        navigator.view.addSubview(overlay)
        defer { overlay.removeFromSuperview() }
        guard await advancePage(forward: forward, navigator: navigator, animated: false) else { return }
        // Readium's navigation promise can resolve before WKWebView has painted the
        // destination locator. Let that render settle before capturing the new leaf.
        try? await Task.sleep(nanoseconds: 120_000_000)
        navigator.view.layoutIfNeeded()
        overlay.isHidden = true
        let destination = navigator.view.snapshotView(afterScreenUpdates: true)
        overlay.isHidden = false
        guard let newPage = destination else { return }

        let bounds = navigator.view.bounds
        oldPage.frame = bounds
        newPage.frame = bounds
        oldPage.isUserInteractionEnabled = false
        newPage.isUserInteractionEnabled = false

        let isRTL = preferences.value.readingDirection == "rtl"
        let turnSign: CGFloat = (forward == !isRTL) ? -1 : 1

        switch preferences.value.animation {
        case .slide:
            newPage.frame = bounds.offsetBy(dx: -turnSign * bounds.width, dy: 0)
            overlay.insertSubview(newPage, belowSubview: oldPage)
            await animate(duration: 0.28) {
                oldPage.transform = CGAffineTransform(translationX: turnSign * bounds.width, y: 0)
                newPage.frame = bounds
            }
            oldPage.removeFromSuperview()
            newPage.removeFromSuperview()
        case .cover:
            newPage.frame = bounds.offsetBy(dx: -turnSign * bounds.width, dy: 0)
            overlay.addSubview(newPage)
            await animate(duration: 0.32) { newPage.frame = bounds }
            oldPage.removeFromSuperview()
            newPage.removeFromSuperview()
        case .simulation:
            let curl: UIView.AnimationOptions = turnSign < 0 ? .transitionCurlUp : .transitionCurlDown
            await animateCurl(from: oldPage, to: newPage, in: overlay, options: curl)
        case .none:
            oldPage.removeFromSuperview()
        }
    }

    @MainActor
    private func animate(duration: TimeInterval, changes: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                changes()
            } completion: { _ in continuation.resume() }
        }
    }

    @MainActor
    private func animateCurl(
        from oldPage: UIView,
        to newPage: UIView,
        in container: UIView,
        options: UIView.AnimationOptions
    ) async {
        oldPage.frame = container.bounds
        newPage.frame = container.bounds
        oldPage.isUserInteractionEnabled = false
        newPage.isUserInteractionEnabled = false
        container.addSubview(oldPage)
        await withCheckedContinuation { continuation in
            UIView.transition(
                with: container,
                duration: 0.62,
                options: [options, .curveEaseInOut],
                animations: {
                    oldPage.removeFromSuperview()
                    container.addSubview(newPage)
                }
            ) { _ in
                oldPage.removeFromSuperview()
                newPage.removeFromSuperview()
                continuation.resume()
            }
        }
    }

    private func pageArrow(forward: Bool) -> String {
        let rtl = preferences.value.readingDirection == "rtl"
        if forward { return rtl ? "chevron.left" : "chevron.right" }
        return rtl ? "chevron.right" : "chevron.left"
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
                    VStack(alignment: .leading) {
                        HStack {
                            Text("首行缩进")
                            Spacer()
                            Text(String(format: "%.2f em", store.value.firstLineIndent))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: binding(\.firstLineIndent), in: 0 ... 3, step: 0.25)
                    }
                    Toggle("去除空行", isOn: binding(\.removeEmptyLines))
                    Text("隐藏不含文字或图片的空白段落。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("使用书籍内置样式", isOn: binding(\.publisherStyles))
                    if store.value.publisherStyles {
                        Text("启用书籍样式时，书籍自身的排版可能覆盖字体、间距和颜色设置。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("页面边距") {
                    marginSlider("上边距", keyPath: \.topMargin)
                    marginSlider("右边距", keyPath: \.rightMargin)
                    marginSlider("下边距", keyPath: \.bottomMargin)
                    marginSlider("左边距", keyPath: \.leftMargin)
                    Text("边距以点为单位，四边可分别调整。")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    if store.value.verticalText && store.value.layout == .paged {
                        Text("竖排分页时，横向滑动每次翻一屏。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if store.value.verticalText {
                        Text("章节内滚动会连续横向滚动；翻页按钮和音量键仍按一屏移动。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("翻页") {
                    Toggle("音量键翻页", isOn: binding(\.volumeButtonsTurnPages))
                    Picker("翻页动画", selection: binding(\.animation)) {
                        ForEach(EPUBTurnAnimation.allCases) { animation in Text(animation.title).tag(animation) }
                    }
                    Text("分页阅读时，滑动、上一页/下一页按钮和音量键使用所选动画。")
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

    private func marginSlider(
        _ title: String,
        keyPath: WritableKeyPath<EPUBReaderPreferences, Double>
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(store.value[keyPath: keyPath])) pt")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: binding(keyPath), in: 0 ... 64, step: 1)
        }
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
