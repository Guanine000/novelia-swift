import SwiftUI
import UIKit
import YueduCoreText

// MARK: - 平移翻页视图
//
// 结构：viewport 内一条 strip，从左到右依次放 [上一页 | 当前页 | 下一页]，
// 静止时 strip.x = -W（当前页正对视口）。拖动只改变 strip.x，两张位图一起移动、
// 左右相接。松手吸附动画也只移动 strip；动画结束后 SwiftUI 提交新的当前页，
// 用同一组 PageID 的缓存位图替换内容并把 strip 归零。
// 目标页位图在拖动开始前就已就位；落页即预览，无重排。
//
// 时序规则（修复闪动/跳回）：
// 1. 拖动中或吸附动画中，apply(images:) 一律缓存不应用——SwiftUI 的任何
//    body 重算都不能在翻页过程中重置 strip 位置；
// 2. 内容未变化（三个槽位位图一致，按 CFEqual 判等）时跳过 layoutStripContent，
//    避免“提交窗口内的旧内容重放”把 strip 归零造成视觉跳回；
// 3. 点击先做链接/注脚命中，命中则不进入翻页判定。

/// 点击命中的链接语义（由模型解析为注脚文本或普通链接提示）。
enum EPUBLinkHit: Equatable {
    case footnote(String)
    case plain(String)
}

struct EPUBPagerView: UIViewControllerRepresentable {
    struct PageImages: Equatable {
        var previous: CGImage?
        var current: CGImage?
        var next: CGImage?
        var size: CGSize = .zero
    }

    /// 返回是否可以朝该方向翻页（目标页必须已排版；动画期间返回 false）。
    var canTurn: (Bool) -> Bool
    /// 完成一次翻页（宿主在动画结束后提交新的当前页并刷新位图）。
    var onCommit: (Bool) -> Void
    /// 翻页动画开始/结束通知；宿主据此在动画期间冻结分页代次。
    var onBlockedTurn: (Bool) -> Void = { _ in }
    var onAnimatingChange: (Bool) -> Void = { _ in }
    /// 点击本地点（当前页本地坐标）的链接/注脚命中测试。
    var linkHitTest: (CGPoint) -> EPUBLinkHit? = { _ in nil }
    /// 页面中部点到图片时打开查看器并返回 true；否则照常显隐工具栏。
    var onImageTap: (CGPoint) -> Bool = { _ in false }
    /// 命中注脚。
    var onNoteTap: (String) -> Void = { _ in }
    /// 命中普通链接（本轮仅提示，不导航）。
    var onPlainLinkTap: (String) -> Void = { _ in }
    /// 点击页面中部（显隐工具栏）。
    var onCenterTap: () -> Void = {}
    /// 长按并拖动页面文字时，根据页面坐标返回 UTF-16 字符范围。
    var selectionRangeAt: (CGPoint) -> NSRange? = { _ in nil }
    /// 当前页中所选文字的高亮矩形。
    var selectionRects: (NSRange) -> [CGRect] = { _ in [] }
    /// 取得选中文本，供系统复制菜单使用。
    var selectedText: (NSRange) -> String? = { _ in nil }
    /// 当前句高亮独立于选字，不重画分页位图。
    var speechRects: [CGRect] = []
    var onSpeechTap: () -> Void = {}
    var onSpeakSelection: (NSRange) -> Void = { _ in }
    /// 选中菜单里的「翻译」；宿主呈现系统翻译面板（iOS 17.4+）。
    var characterLookup: ((String) -> Void)? = nil
    var selectionTranslate: ((String) -> Void)? = { _ in }
    /// 三页位图由宿主从同一份排版缓存派生；每次 SwiftUI 更新都会重放。
    var curlEnabled = false
    var paperInsets: UIEdgeInsets = .zero
    var paperColor: UIColor = .systemBackground
    var paperBackground: UIImage?
    var images: PageImages

    func makeUIViewController(context: Context) -> EPUBPagerContainer {
        let container = EPUBPagerContainer()
        container.loadViewIfNeeded()
        updateUIViewController(container, context: context)
        return container
    }

    func updateUIViewController(_ container: EPUBPagerContainer, context: Context) {
        let view = container.interaction
        view.canTurnProvider = canTurn
        view.commitHandler = onCommit
        view.animatingChangeHandler = onAnimatingChange
        view.blockedTurnHandler = onBlockedTurn
        view.linkHitTestProvider = linkHitTest
        view.imageTapProvider = onImageTap
        view.noteTapHandler = onNoteTap
        view.plainLinkTapHandler = onPlainLinkTap
        view.centerTapHandler = onCenterTap
        view.selectionRangeProvider = selectionRangeAt
        view.selectionRectsProvider = selectionRects
        view.selectedTextProvider = selectedText
        view.speechTapHandler = onSpeechTap
        view.speakSelectionHandler = onSpeakSelection
        view.selectionTranslateHandler = selectionTranslate
        view.characterLookupHandler = characterLookup
        container.update(images: images, curl: curlEnabled, insets: paperInsets,
                         color: paperColor, background: paperBackground)
        view.applySpeechRects(speechRects)
    }
}

final class EPUBPagerUIView: UIView, UIGestureRecognizerDelegate {
    var blockedTurnHandler: ((Bool) -> Void)?
    var canTurnProvider: ((Bool) -> Bool)?
    var commitHandler: ((Bool) -> Void)?
    var animatingChangeHandler: ((Bool) -> Void)?
    var linkHitTestProvider: ((CGPoint) -> EPUBLinkHit?)?
    var imageTapProvider: ((CGPoint) -> Bool)?
    var noteTapHandler: ((String) -> Void)?
    var plainLinkTapHandler: ((String) -> Void)?
    var centerTapHandler: (() -> Void)?
    var selectionRangeProvider: ((CGPoint) -> NSRange?)?
    var selectionRectsProvider: ((NSRange) -> [CGRect])?
    var selectedTextProvider: ((NSRange) -> String?)?
    /// 选中菜单里的「翻译」；宿主呈现系统翻译面板（iOS 17.4+）。
    var characterLookupHandler: ((String) -> Void)?
    var selectionTranslateHandler: ((String) -> Void)?
    private let strip = UIView()
    private let speechLayer = CAShapeLayer()
    private let previousImageView = UIImageView()
    private let currentImageView = UIImageView()
    private let nextImageView = UIImageView()
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private var adjustingStart = false
    private var selectionBounds: [CGRect] = []
    fileprivate var longPressGesture: UILongPressGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!
    var curlTurnHandler: ((Bool) -> Void)?
    var curlSelectionHandler: ((Bool) -> Void)?
    var speechTapHandler: (() -> Void)?
    var speakSelectionHandler: ((NSRange) -> Void)?
    private var spokenRects: [CGRect] = []
    private var editMenuInteraction: UIEditMenuInteraction!

    private var pageSize: CGSize = .zero
    private var images: EPUBPagerView.PageImages = .init(previous: nil, current: nil, next: nil)
    private var isAnimating = false
    private var isDragActive = false
    private var panBaseX: CGFloat = 0
    private var selectionInitialRange: NSRange?
    private var selectionMovingRange: NSRange?
    private var selectedText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear

        strip.frame = bounds
        addSubview(strip)

        for imageView in [previousImageView, currentImageView, nextImageView] {
            imageView.contentMode = .topLeft
            imageView.clipsToBounds = true
            strip.addSubview(imageView)
        }
        speechLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.30).cgColor
        currentImageView.layer.addSublayer(speechLayer)
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
        currentImageView.layer.addSublayer(selectionLayer)
        handlesLayer.fillColor = UIColor.systemBlue.cgColor
        currentImageView.layer.addSublayer(handlesLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture = pan
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.45
        longPressGesture.allowableMovement = 28
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)
        tap.require(toFail: longPressGesture)
        // 让明确的长按手势接管本次触摸序列，避免分页拖动手势
        // 在选择焦点移动之前消耗拖动事件。
        pan.require(toFail: longPressGesture)

        editMenuInteraction = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: 内容更新

    func apply(images: EPUBPagerView.PageImages) {
        // 1) 拖动/吸附中不重放内容，缓存待动画结束再应用。
        if isDragActive || isAnimating {
            self.images = images
            return
        }
        // 2) 内容未变化时不触碰布局（提交窗口内的旧内容重放不再重置 strip）。
        if Self.imagesEqual(images, self.images) { return }
        clearSelection()
        self.images = images
        pageSize = images.size
        layoutStripContent()
    }

    func applySpeechRects(_ rects: [CGRect]) {
        spokenRects = rects
        let path = UIBezierPath()
        for rect in rects { path.append(UIBezierPath(rect: rect)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        speechLayer.frame = currentImageView.bounds
        speechLayer.path = path.cgPath
        CATransaction.commit()
    }

    private static func imagesEqual(_ a: EPUBPagerView.PageImages,
                                    _ b: EPUBPagerView.PageImages) -> Bool {
        sameImage(a.previous, b.previous)
            && sameImage(a.current, b.current)
            && sameImage(a.next, b.next)
            && a.size == b.size
    }

    /// CFEqual 不接受 NULL，空槽位单独比较。
    fileprivate static func sameImage(_ a: CGImage?, _ b: CGImage?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CFEqual(x, y)
        default: return false
        }
    }

    private func layoutStripContent() {
        let width = max(bounds.width, pageSize.width)
        let height = max(bounds.height, pageSize.height)
        let imageViews: [(UIImageView, CGImage?)] = [
            (previousImageView, images.previous),
            (currentImageView, images.current),
            (nextImageView, images.next),
        ]
        for (index, item) in imageViews.enumerated() {
            let frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
            item.0.frame = frame
            // 位图以设备像素渲染，按屏幕 scale 还原为点尺寸，避免 3x 放大。
            item.0.image = item.1.map {
                UIImage(cgImage: $0, scale: UIScreen.main.scale, orientation: .up)
            }
        }
        selectionLayer.frame = currentImageView.bounds
        handlesLayer.frame = currentImageView.bounds
        // 当前页始终位于中间槽位。
        strip.frame = CGRect(x: -width, y: 0, width: width * 3, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 边界变化（旋转/首次布局）时同步槽位尺寸；拖动/动画中不动。
        if !isDragActive, !isAnimating, bounds.width > 0, bounds.size != images.size {
            images.size = bounds.size
            pageSize = bounds.size
            layoutStripContent()
        }
    }

    /// 系统卷页承载纸面，本视图只保留正文坐标内的交互与独立高亮。
    func configureCurl(_ enabled: Bool) {
        for image in [previousImageView, currentImageView, nextImageView] { image.isHidden = enabled }
        // 高亮图层挂在当前位图上，因此隐藏图片时改为只清空 UIImage，保留图层。
        currentImageView.isHidden = false
        if enabled { previousImageView.image = nil; currentImageView.image = nil; nextImageView.image = nil }
        else { layoutStripContent() }
        updateCurlSelection()
    }

    private func updateCurlSelection() {
        guard curlTurnHandler != nil else { panGesture.isEnabled = true; return }
        let selecting = selectionInitialRange != nil
        panGesture.isEnabled = selecting
        curlSelectionHandler?(selecting)
    }

    func setCurlAnimating(_ active: Bool) {
        isAnimating = active
        animatingChangeHandler?(active)
        layer.opacity = active ? 0 : 1
    }

    // MARK: 手势

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = max(bounds.width, pageSize.width)
        guard width > 0 else { return }

        if selectionInitialRange != nil, gesture.state != .began {
            if gesture.state == .changed, let range = selectionRangeProvider?(gesture.location(in: self)) {
                if adjustingStart { selectionInitialRange = range }
                else { selectionMovingRange = range }
                updateSelectionHighlight()
            } else if gesture.state == .ended || gesture.state == .cancelled {
                presentCopyMenu(at: gesture.location(in: self))
            }
            return
        }
        switch gesture.state {
        case .began:
            if selectionInitialRange != nil {
                guard let first = selectionBounds.first, let last = selectionBounds.last else { return }
                let point = gesture.location(in: self)
                let start = CGPoint(x: first.minX, y: first.minY)
                let end = CGPoint(x: last.maxX, y: last.maxY)
                adjustingStart = hypot(point.x - start.x, point.y - start.y) < hypot(point.x - end.x, point.y - end.y)
                editMenuInteraction.dismissMenu()
                return
            }
            if isAnimating {
                gesture.state = .cancelled
                return
            }
            isDragActive = true
            panBaseX = -width

        case .changed:
            guard !isAnimating, isDragActive else { return }
            let translation = gesture.translation(in: self).x
            var offset = panBaseX + translation
            // 没有对应页位图（或不可翻）时，该方向停住不动。
            if translation > 0 {
                let canTurnBack = (canTurnProvider?(false) ?? false) && images.previous != nil
                if !canTurnBack { offset = -width }
            } else if translation < 0 {
                let canTurnForward = (canTurnProvider?(true) ?? false) && images.next != nil
                if !canTurnForward { offset = -width }
            }
            offset = min(0, max(-2 * width, offset))
            strip.frame.origin.x = offset

        case .ended, .cancelled:
            guard !isAnimating, isDragActive else { return }
            isDragActive = false
            let translation = gesture.translation(in: self).x
            let velocity = gesture.velocity(in: self).x
            let threshold = width / 4
            var forward: Bool?
            if translation < -threshold || velocity < -900 { forward = true }
            else if translation > threshold || velocity > 900 { forward = false }
            guard let direction = forward,
                  (canTurnProvider?(direction == true) ?? false),
                  (direction == true ? images.next : images.previous) != nil else {
                snapBack()
                if gesture.state == .ended, let direction = forward { blockedTurnHandler?(direction) }
                return
            }
            completeTurn(forward: direction == true)

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !isAnimating, !isDragActive else { return }
        let location = gesture.location(in: self)
        let width = max(bounds.width, pageSize.width)

        if selectionInitialRange != nil {
            clearSelection()
            return
        }

        // 1) 链接/注脚命中优先：当前页槽位与视口重合，视图坐标即页本地坐标。
        if let hit = linkHitTestProvider?(location) {
            switch hit {
            case .footnote(let text):
                noteTapHandler?(text)
            case .plain(let href):
                plainLinkTapHandler?(href)
            }
            return
        }

        if spokenRects.contains(where: { $0.contains(location) }) { speechTapHandler?(); return }

        // 2) 中部三分之一：点到图片时打开查看器，否则显隐工具栏。
        if location.x > width / 3, location.x < width * 2 / 3 {
            if imageTapProvider?(location) == true { return }
            centerTapHandler?()
            return
        }

        // 3) 左右三分之一：翻页。
        let forward = location.x >= width * 2 / 3
        guard (canTurnProvider?(forward) ?? false),
              (forward ? images.next : images.previous) != nil else { blockedTurnHandler?(forward); return }
        completeTurn(forward: forward)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard !isAnimating, !isDragActive else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let range = selectionRangeProvider?(point), range.length > 0 else { return }
            selectionInitialRange = range
            selectionMovingRange = range
            updateSelectionHighlight()
        case .changed:
            guard selectionInitialRange != nil,
                  let range = selectionRangeProvider?(point), range.length > 0 else { return }
            selectionMovingRange = range
            updateSelectionHighlight()
        case .ended:
            presentCopyMenu(at: point)
        case .cancelled, .failed:
            clearSelection()
        default:
            break
        }
    }

    private func updateSelectionHighlight() {
        guard let initial = selectionInitialRange, let moving = selectionMovingRange else {
            selectionLayer.path = nil
            selectedText = nil
            return
        }
        let start = min(initial.location, moving.location)
        let range = NSRange(location: start, length: max(NSMaxRange(initial), NSMaxRange(moving)) - start)
        selectedText = selectedTextProvider?(range)
        let rects = selectionRectsProvider?(range) ?? []
        selectionBounds = rects
        let path = UIBezierPath()
        for rect in rects {
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))
        }
        selectionLayer.path = path.cgPath
        let handles = UIBezierPath()
        if let first = rects.first, let last = rects.last {
            handles.append(UIBezierPath(ovalIn: CGRect(x: first.minX - 6, y: first.minY - 10, width: 12, height: 12)))
            handles.append(UIBezierPath(ovalIn: CGRect(x: last.maxX - 6, y: last.maxY - 2, width: 12, height: 12)))
        }
        handlesLayer.path = handles.cgPath
        updateCurlSelection()
    }

    private func presentCopyMenu(at point: CGPoint) {
        guard selectedText?.isEmpty == false else { return }
        if let initial = selectionInitialRange, let moving = selectionMovingRange, initial.location > moving.location {
            selectionInitialRange = moving
            selectionMovingRange = initial
        }
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: configuration)
    }

    fileprivate func clearSelection() {
        editMenuInteraction.dismissMenu()
        selectionInitialRange = nil
        selectionMovingRange = nil
        selectedText = nil
        selectionLayer.path = nil
        handlesLayer.path = nil
        selectionBounds = []
        updateCurlSelection()
    }

    private func snapBack() {
        let width = max(bounds.width, pageSize.width)
        isAnimating = true
        animatingChangeHandler?(true)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.strip.frame.origin.x = -width
        } completion: { _ in
            self.isAnimating = false
            self.animatingChangeHandler?(false)
            self.apply(images: self.images)
        }
    }

    /// 吸附到目标页：动画只移动 strip，结束后回调宿主提交新页（宿主用同一 PageID 的
    /// 缓存位图刷新，strip 归零后视觉不变）。
    private func completeTurn(forward: Bool) {
        if let curlTurnHandler { curlTurnHandler(forward); return }
        let width = max(bounds.width, pageSize.width)
        isAnimating = true
        animatingChangeHandler?(true)
        let targetX = forward ? -2 * width : 0
        UIView.animate(withDuration: 0.28, delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            self.strip.frame.origin.x = targetX
        } completion: { _ in
            self.isAnimating = false
            self.animatingChangeHandler?(false)
            self.commitHandler?(forward)
            // 提交引发的 SwiftUI 更新随后带来新内容；在此之前先按缓存应用一次，
            // 保证 strip 归零（新旧中间槽位像素一致，不会闪）。
            self.apply(images: self.images)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

extension EPUBPagerUIView: UIEditMenuInteractionDelegate {
    private func presentSelectionController(_ controller: UIViewController) {
        editMenuInteraction.dismissMenu()
        var responder: UIResponder? = self
        while let current = responder {
            if let presenter = current as? UIViewController {
                presenter.present(controller, animated: true)
                return
            }
            responder = current.next
        }
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let selectedText, !selectedText.isEmpty else { return nil }
        let copy = UIAction(title: "拷贝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let selectedText = self?.selectedText else { return }
            UIPasteboard.general.string = selectedText
        }
        let search = UIAction(title: "搜索网页", image: UIImage(systemName: "magnifyingglass")) { _ in
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: selectedText)]
            if let url = components.url { UIApplication.shared.open(url) }
        }
        let lookup = UIAction(title: "查询", image: UIImage(systemName: "book")) { [weak self] _ in
            guard let self else { return }
            self.presentSelectionController(UIReferenceLibraryViewController(term: selectedText))
        }
        let share = UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let controller = UIActivityViewController(activityItems: [selectedText], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = self
            controller.popoverPresentationController?.sourceRect = CGRect(origin: configuration.sourcePoint, size: CGSize(width: 1, height: 1))
            self.presentSelectionController(controller)
        }
        var items: [UIMenuElement] = [copy, lookup]
        if let handler = characterLookupHandler {
            items.append(UIAction(title: "人物词条", image: UIImage(systemName: "person.text.rectangle")) { [weak self] _ in
                self?.clearSelection(); handler(selectedText)
            })
        }
        if #available(iOS 17.4, *), let translateHandler = selectionTranslateHandler {
            items.append(UIAction(title: "翻译", image: UIImage(systemName: "translate")) { _ in
                translateHandler(selectedText)
            })
        }
        items.append(contentsOf: [speak, search, share])
        return UIMenu(children: items)
    }

    /// 选中菜单里的「从此句朗读」：以选区起点作为章内源文本偏移起播。
    private var speak: UIAction {
        UIAction(title: "从此句朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
            guard let self, let first = self.selectionInitialRange, let last = self.selectionMovingRange else { return }
            let start = min(first.location, last.location)
            let range = NSRange(location: start, length: max(NSMaxRange(first), NSMaxRange(last)) - start)
            self.clearSelection(); self.speakSelectionHandler?(range)
        }
    }
}

/// SwiftUI 拥有的原生分页宿主。纸面使用全屏坐标，交互视图保留原正文坐标；
/// 只缓存前/当前/后三张纸，不改变模型的分页结果和进度所有权。
final class EPUBPagerContainer: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let interaction = EPUBPagerUIView()
    private var pager: UIPageViewController?
    private var pages: [Int: EPUBCurlSheet] = [:]
    private var input = EPUBPagerView.PageImages(previous: nil, current: nil, next: nil)
    private var deferred: (EPUBPagerView.PageImages, Bool, UIEdgeInsets, UIColor, UIImage?)?
    private var paperInsets = UIEdgeInsets.zero
    private var paperColor = UIColor.systemBackground
    private var paperBackground: UIImage?
    private var paperSize = CGSize.zero
    private var turning = false
    private var staleCurrent: CGImage?
    private var awaitingCommit = false
    private var curl = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(interaction)
    }

    func update(images: EPUBPagerView.PageImages, curl: Bool, insets: UIEdgeInsets, color: UIColor, background: UIImage?) {
        if turning { deferred = (images, curl, insets, color, background); return }
        // 已经显示目标快照时，等待模型提交，不能重放提交前的当前页。
        if awaitingCommit, EPUBPagerUIView.sameImage(images.current, staleCurrent), self.curl == curl { return }
        awaitingCommit = false
        let changed = input != images || self.curl != curl || paperInsets != (curl ? insets : .zero)
            || !paperColor.isEqual(color) || paperBackground !== background
        input = images; self.curl = curl; paperInsets = curl ? insets : .zero
        paperColor = color; paperBackground = background
        if curl, pager == nil { installCurl() }
        if !curl { removeCurl() }
        interaction.apply(images: images)
        interaction.configureCurl(curl)
        layoutSurfaces()
        if curl, changed { rebuildSheets() }
    }

    private func installCurl() {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.dataSource = self; controller.delegate = self
        addChild(controller)
        controller.view.backgroundColor = .clear
        view.insertSubview(controller.view, belowSubview: interaction)
        controller.didMove(toParent: self)
        pager = controller
        // 迁移公开 pan 到共同祖先，让正文交互层与纸面共享拖动；
        // 系统 tap 关闭，保留现有链接/注脚优先和中部显隐规则。
        for gesture in controller.gestureRecognizers {
            if gesture is UIPanGestureRecognizer {
                view.addGestureRecognizer(gesture)
                gesture.require(toFail: interaction.longPressGesture)
            } else { gesture.isEnabled = false }
        }
        interaction.curlTurnHandler = { [weak self] in self?.turn(forward: $0) }
        interaction.curlSelectionHandler = { [weak controller] selecting in
            controller?.gestureRecognizers.filter { $0 is UIPanGestureRecognizer }.forEach { $0.isEnabled = !selecting }
        }
    }

    private func removeCurl() {
        guard let pager else { return }
        for gesture in pager.gestureRecognizers where gesture.view === view { view.removeGestureRecognizer(gesture) }
        pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        self.pager = nil; pages = [:]; paperSize = .zero
        interaction.curlTurnHandler = nil; interaction.curlSelectionHandler = nil
    }

    private func layoutSurfaces() {
        pager?.view.frame = view.bounds
        interaction.frame = curl
            ? CGRect(origin: CGPoint(x: paperInsets.left, y: paperInsets.top), size: input.size)
            : view.bounds
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !turning else { return }
        layoutSurfaces()
        if curl, paperSize != view.bounds.size { rebuildSheets() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if turning { finishTurn(completed: false) }
    }

    private func rebuildSheets() {
        guard let pager, !turning, view.bounds.width > 0, view.bounds.height > 0 else { return }
        paperSize = view.bounds.size
        var result: [Int: EPUBCurlSheet] = [:]
        for (slot, image) in [(-1, input.previous), (0, input.current), (1, input.next)] {
            guard let image else { continue }
            result[slot] = EPUBCurlSheet(slot: slot, image: compose(image))
        }
        pages = result
        if let current = pages[0] { pager.setViewControllers([current], direction: .forward, animated: false) }
    }
    private func compose(_ image: CGImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            paperColor.setFill(); context.fill(view.bounds)
            if let background = paperBackground {
                let scale = max(view.bounds.width / background.size.width, view.bounds.height / background.size.height)
                let size = CGSize(width: background.size.width * scale, height: background.size.height * scale)
                background.draw(in: CGRect(x: (view.bounds.width-size.width)/2, y: (view.bounds.height-size.height)/2, width: size.width, height: size.height))
            }
            // 延展位图最外侧的背景像素，避免书籍彩色扉页或自定义背景在安全区出现异色带。
            let x = paperInsets.left, y = paperInsets.top
            let w = input.size.width, h = input.size.height
            let right = max(0, view.bounds.width-x-w), bottom = max(0, view.bounds.height-y-h)
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            func edge(_ source: CGRect, _ target: CGRect) {
                guard target.width > 0, target.height > 0, let crop = image.cropping(to: source) else { return }
                UIImage(cgImage: crop).draw(in: target)
            }
            edge(CGRect(x: 0, y: 0, width: iw, height: 1), CGRect(x: x, y: 0, width: w, height: y))
            edge(CGRect(x: 0, y: ih-1, width: iw, height: 1), CGRect(x: x, y: y+h, width: w, height: bottom))
            edge(CGRect(x: 0, y: 0, width: 1, height: ih), CGRect(x: 0, y: y, width: x, height: h))
            edge(CGRect(x: iw-1, y: 0, width: 1, height: ih), CGRect(x: x+w, y: y, width: right, height: h))
            for (sx, dx, dw) in [(CGFloat(0), CGFloat(0), x), (iw-1, x+w, right)] {
                edge(CGRect(x: sx, y: 0, width: 1, height: 1), CGRect(x: dx, y: 0, width: dw, height: y))
                edge(CGRect(x: sx, y: ih-1, width: 1, height: 1), CGRect(x: dx, y: y+h, width: dw, height: bottom))
            }
            UIImage(cgImage: image).draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
    }
    private func neighbor(_ controller: UIViewController, forward: Bool) -> UIViewController? {
        guard !awaitingCommit, let sheet = controller as? EPUBCurlSheet else { return nil }
        let slot = sheet.slot + (forward ? 1 : -1)
        guard let page = pages[slot] else { return nil }
        if slot != 0, !turning, interaction.canTurnProvider?(forward) != true { return nil }
        return page
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbor(viewController, forward: false)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbor(viewController, forward: true)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { beginTurn() }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) { finishTurn(completed: completed) }

    private func beginTurn() {
        guard !turning else { return }
        turning = true
        interaction.clearSelection()
        interaction.setCurlAnimating(true)
    }
    private func finishTurn(completed: Bool) {
        guard turning else { return }
        let slot = (pager?.viewControllers?.first as? EPUBCurlSheet)?.slot ?? 0
        turning = false
        interaction.setCurlAnimating(false)
        if completed, slot != 0 {
            staleCurrent = input.current; awaitingCommit = true
            interaction.commitHandler?(slot > 0)
        } else { rebuildSheets() }
        if let deferred {
            self.deferred = nil
            update(images: deferred.0, curl: deferred.1, insets: deferred.2, color: deferred.3, background: deferred.4)
        }
    }
    private func turn(forward: Bool) {
        guard !turning, !awaitingCommit else { return }
        guard let pager, interaction.canTurnProvider?(forward) == true,
              let target = pages[forward ? 1 : -1] else { interaction.blockedTurnHandler?(forward); return }
        beginTurn()
        pager.setViewControllers([target], direction: forward ? .forward : .reverse, animated: true) { [weak self] finished in
            self?.finishTurn(completed: finished)
        }
    }
}

/// 动画开始前合成的一张不可变纸面，包含正文与上下页边背景。
private final class EPUBCurlSheet: UIViewController {
    let slot: Int
    private let image: UIImage
    init(slot: Int, image: UIImage) { self.slot = slot; self.image = image; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        view = imageView
    }
}
