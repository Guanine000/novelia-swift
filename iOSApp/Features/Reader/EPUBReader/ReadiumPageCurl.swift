// SPDX-License-Identifier: GPL-3.0-only
import Combine
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

/// Readium 宿主拥有的卷页适配器。真实 WebView 保留正文交互，系统卷页只展示有限快照。
/// 宿主另持一个复用同一 Publication 与配置的预取导航器；真实导航器不参与预取。
/// 基础三页之外沿阅读方向预热一页，取消不移动正文，完成后等待正式 Locator 再提交位置。
@MainActor
final class ReadiumPageCurlController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private weak var model: ReadiumEPUBReaderModel?
    private weak var host: UIViewController?
    private weak var navigator: EPUBNavigatorViewController?
    private var snapshotNavigator: EPUBNavigatorViewController?
    private var snapshotConfiguration: String?
    private let canvas = ReadiumCurlCanvas()
    private let cover = UIImageView()
    // 空遮罩只隐藏纸面渲染，不把系统卷页视图设为不可见，公开 pan 仍可在共同祖先上识别。
    private let paperMask = CALayer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pager: UIPageViewController
    private var sheets: [Int: ReadiumCurlSheet] = [:]
    private var work: Task<Void, Never>?
    private var enabled = false
    private var isDisappeared = false
    private var cancellationDepth = 0
    private var preparedKey: String?
    private var failedKey: String?
    /// 上一次翻页已截好的「落页」和「原当前页」；重建三页时直接复用，少拍两张。
    private var carried: (current: ReadiumCurlSheet, other: ReadiumCurlSheet, otherSlot: Int)?
#if DEBUG
    private var turnStartedAt: CFTimeInterval?
#endif
    private func recordReadyLatency() {
#if DEBUG
        if let start = turnStartedAt {
            model?.curlTurnReadyMilliseconds = Int((CACurrentMediaTime() - start) * 1000)
            turnStartedAt = nil
        }
#endif
    }
    private enum AheadResult { case page(ReadiumCurlSheet), boundary }
    /// 三张基础纸面之外，沿阅读方向预热一张；独立任务不锁住正文或发布进度。
    private var ahead: (key: String, forward: Bool, configuration: String, task: Task<AheadResult?, Never>)?
    private var preferredForward = true
    private var renderingConfiguration: String? {
        guard let model, let navigator else { return nil }
        return "\(model.navigatorRevision)|\(model.curlAppearanceKey)|\(navigator.view.bounds.size)|\(view.safeAreaInsets)"
    }
    private var turning = false
    private var transaction: UUID?
    private var queuedDirection: Bool?
    private var speechObservation: AnyCancellable?
    private var boundPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private lazy var coldPan = UIPanGestureRecognizer(target: self, action: #selector(coldSwipe(_:)))
    private lazy var selectionGate = ReadiumCurlSelectionGate { [weak self] in self?.navigator?.currentSelection != nil }
    private lazy var selectionPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressObserved(_:)))

    init(model: ReadiumEPUBReaderModel, host: UIViewController, navigator: EPUBNavigatorViewController) {
        self.model = model; self.host = host; self.navigator = navigator
        pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: (model.curlRightToLeft ? UIPageViewController.SpineLocation.max : .min).rawValue)])
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = canvas }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager); view.addSubview(pager.view); pager.didMove(toParent: self)
        pager.dataSource = self; pager.delegate = self
        // 首次预取期间也必须有一个页面；空 pageCurl 容器在旋转时会触发 UIKit 断言。
        pager.setViewControllers([UIViewController()], direction: .forward, animated: false)
        pager.view.backgroundColor = .clear; pager.view.layer.mask = paperMask
        cover.contentMode = .scaleToFill; cover.isHidden = true; view.addSubview(cover)
        spinner.hidesWhenStopped = true; view.addSubview(spinner)
        selectionPress.minimumPressDuration = 0.35
        selectionPress.cancelsTouchesInView = false; selectionPress.delegate = self
        coldPan.maximumNumberOfTouches = 1; coldPan.delegate = self
        selectionGate.cancelsTouchesInView = false; selectionGate.delegate = self
        coldPan.require(toFail: selectionPress)
        if let host {
            host.view.addGestureRecognizer(coldPan)
            host.view.addGestureRecognizer(selectionGate)
            host.view.addGestureRecognizer(selectionPress)

            for gesture in pager.gestureRecognizers {
                if gesture is UIPanGestureRecognizer {
                    host.view.addGestureRecognizer(gesture)
                    gesture.require(toFail: selectionGate)
                    gesture.require(toFail: selectionPress)
                } else { gesture.isEnabled = false }
            }
        }
        model?.onCurlTurn = { [weak self] in self?.requestTurn(forward: $0) ?? false }
        model?.cancelCurl = { [weak self] in await self?.cancelAndWait() }
        speechObservation = model?.speech.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        setPansReady(false)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pager.view.frame = view.bounds; cover.frame = view.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); isDisappeared = false; refresh() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isDisappeared = true
        ahead?.task.cancel()
        setPansReady(false)
        if !turning { work?.cancel() }
        else if work == nil { finishTurn(completed: false) }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        Task { [weak self] in await self?.cancelAndWait() }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.refresh() }
    }

    func detach() {
        enabled = false
        setPansReady(false)
        if !turning { work?.cancel() }
        for gesture in [coldPan, selectionGate, selectionPress] as [UIGestureRecognizer] { host?.view.removeGestureRecognizer(gesture) }
        for gesture in pager.gestureRecognizers where gesture.view === host?.view { host?.view.removeGestureRecognizer(gesture) }
        model?.onCurlTurn = nil; model?.cancelCurl = nil
        Task { [self] in await cancelAndWait() }
    }

    func configure(enabled: Bool) { self.enabled = enabled; refresh() }

    private var available: Bool {
        enabled && !isDisappeared && cancellationDepth == 0 && model?.status == .ready && model?.speech.isActive == false && navigator?.settings.scroll == false
    }
    private var key: String? {
        guard let model, let location = model.locator, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        return "\(model.navigatorRevision)|\((try? location.jsonString()) ?? "")|\(model.curlAppearanceKey)|\(view.bounds.size)|\(view.safeAreaInsets)|\(navigator?.view.bounds.size ?? .zero)"
    }
    private func refresh() {
        guard isViewLoaded, cancellationDepth == 0 else { return }
        bindScrollGestures()
        guard available, view.window != nil, let key else {
            if model?.curlReady == true { model?.curlReady = false }
            setPansReady(false)
            if !turning { work?.cancel() }
            else if work == nil { finishTurn(completed: false) }
            if work == nil, !turning { carried = nil; discardSnapshot() }
            return
        }
        guard work == nil, !turning, navigator?.currentSelection == nil else { return }
        if preparedKey == key {
            if model?.curlReady == false { model?.curlReady = true }
            setPansReady(true)
            startLookahead(forward: preferredForward)
            return
        }
        guard failedKey != key else { setPansReady(false); return }
        setPansReady(false)
        work = Task { [weak self] in await self?.prepare(key: key) }
    }
    private func setPansReady(_ ready: Bool) {
        for gesture in pager.gestureRecognizers where gesture is UIPanGestureRecognizer { gesture.isEnabled = ready && available }
        coldPan.isEnabled = available && !ready
    }
    private func bindScrollGestures() {
        guard let root = navigator?.view else { return }
        func walk(_ view: UIView, insideWeb: Bool) {
            if let scroll = view as? UIScrollView, !boundPans.contains(scroll.panGestureRecognizer) {
                boundPans.add(scroll.panGestureRecognizer)
                for gesture in pager.gestureRecognizers where gesture is UIPanGestureRecognizer {
                    scroll.panGestureRecognizer.require(toFail: gesture)
                }
                scroll.panGestureRecognizer.require(toFail: coldPan)
            }
            let web = insideWeb || view is WKWebView
            view.subviews.forEach { walk($0, insideWeb: web) }
        }
        walk(root, insideWeb: false)
    }

    private func prepare(key: String) async {
        guard let model, let host, let real = navigator else { work = nil; return }
#if DEBUG
        model.curlPreparationCount += 1
#endif
        let previousAhead = ahead?.task
        ahead = nil
        previousAhead?.cancel()
        if let previousAhead { _ = await previousAhead.value }
        guard !Task.isCancelled, available, model.navigator === real, key == self.key,
              let configuration = renderingConfiguration else {
            work = nil; discardSnapshot()
            if !Task.isCancelled, model.navigator === real { refresh() }
            return
        }
        if snapshotConfiguration != configuration { carried = nil; discardSnapshot() }
        let reused = snapshotNavigator != nil
        let snapshotNav: EPUBNavigatorViewController
        do {
            if let existing = snapshotNavigator { snapshotNav = existing }
            else {
                guard let created = try model.makeCurlSnapshotNavigator() else { work = nil; return }
                snapshotNav = created
                snapshotNavigator = created; snapshotConfiguration = configuration
                host.addChild(created)
                host.view.insertSubview(created.view, belowSubview: real.view)
                created.view.frame = real.view.frame
                // 真实正文有透明区域，预取层不能从后面露出；遮罩不影响 WebKit 的内容快照。
                created.view.layer.mask = CALayer()
                created.view.isUserInteractionEnabled = false
                created.didMove(toParent: host)
            }
        } catch { work = nil; model.curlError = String(describing: error); return }
        guard let token = model.beginCurlPreview(snapshot: snapshotNav) else { work = nil; return }
        transaction = token
        canvas.blocksTouches = true; spinner.startAnimating()
        let carry = carried
        carried = nil
        var phase = "origin"
        var result: [Int: ReadiumCurlSheet] = [:]
        if let carry {
            result[0] = ReadiumCurlSheet(slot: 0, image: carry.current.image, location: carry.current.location)
            result[carry.otherSlot] = ReadiumCurlSheet(slot: carry.otherSlot, image: carry.other.image, location: carry.other.location)
        }
        // 翻页后当前页与一侧相邻页已有截图，只补拍缺失的一侧；首次进入仍拍三页。
        let gaps = [true, false].filter { result[$0 ? 1 : -1] == nil }
        do {
            // 上次准备结束时刻意把预取导航器留在相邻页；若它已经在当前页，省一次导航。
            let alreadyAtOrigin = previousAhead == nil && reused && snapshotNav.currentLocation.map { origin in
                model.locator.map { Self.samePage(origin, $0) } ?? false
            } ?? false
            if (reused || carry != nil), !alreadyAtOrigin {
                guard await model.restoreCurlPreview(token) else { throw CurlError.restore }
            }
            phase = "current"
            if carry != nil {
                if let current = result[0] { cover.image = current.image; cover.isHidden = false }
            } else {
                try await waitForPage()
                guard key == self.key else { throw CancellationError() }
                guard let origin = model.locator else { throw CurlError.notReady }
                let current = try await snapshot()
                result[0] = ReadiumCurlSheet(slot: 0, image: current, location: origin)
                cover.image = current; cover.isHidden = false; canvas.blocksTouches = true
                spinner.startAnimating()
            }
            for forward in gaps {
                try Task.checkCancellation()
                guard key == self.key else { throw CancellationError() }
                phase = forward ? "next" : "previous"
                if let location = try await model.previewCurlNeighbor(forward: forward, transaction: token) {
                    try await waitForPage()
                    result[forward ? 1 : -1] = ReadiumCurlSheet(slot: forward ? 1 : -1, image: try await snapshot(), location: location)
                }
                // 增量准备只补一侧时把预取导航器留在该侧，下一次同向翻页就无需再导航回来。
                phase = "restore"
                if carry == nil || forward != gaps.last {
                    guard await model.restoreCurlPreview(token) else { throw CurlError.restore }
                    try await waitForPage()
                }
            }
            try Task.checkCancellation()
            guard key == self.key else { throw CancellationError() }
            let finished = await model.finishCurlPreview(token, target: nil)
            transaction = nil
            guard finished != nil else { throw CurlError.restore }

            sheets = result; preparedKey = key; failedKey = nil
            model.curlReady = key == self.key
            if model.curlReady { recordReadyLatency() }
            if let current = result[0] { pager.setViewControllers([current], direction: .forward, animated: false) }
        } catch {
            let cleanup = Task { @MainActor in await model.finishCurlPreview(token, target: nil) }
            _ = await cleanup.value
            transaction = nil; preparedKey = nil
            model.curlReady = false
            discardSnapshot()
            if !(error is CancellationError), !Task.isCancelled, key == self.key {
#if DEBUG
                model.curlPreparationFailure = "\(phase): \(error)"
#endif
                failedKey = key
                model.curlError = "暂时无法准备仿真翻页，请重试或切换为跟手平移。"
            }
        }
        work = nil; spinner.stopAnimating(); cover.isHidden = true; canvas.blocksTouches = false
        if !available { discardSnapshot() }
        setPansReady(preparedKey == self.key)

        guard !Task.isCancelled else { return }
        if model.curlReady { startLookahead(forward: preferredForward) }
        if let direction = queuedDirection, available, preparedKey == self.key {
            queuedDirection = nil
            _ = requestTurn(forward: direction)
        } else if available, self.key != key { refresh() }
    }

    private func visibleWebViews(in source: EPUBNavigatorViewController? = nil) -> [WKWebView] {
        guard let root = (source ?? snapshotNavigator ?? navigator)?.view else { return [] }
        var result: [WKWebView] = []
        func walk(_ candidate: UIView) {
            guard !candidate.isHidden, candidate.alpha > 0.01 else { return }
            if let web = candidate as? WKWebView,
               web.convert(web.bounds, to: view).intersection(view.bounds).width > 1,
               web.convert(web.bounds, to: view).intersection(view.bounds).height > 1 { result.append(web) }
            candidate.subviews.forEach(walk)
        }
        walk(root); return result
    }
    private func waitForPage(in source: EPUBNavigatorViewController? = nil) async throws {
        var previous = "", stable = 0
        for _ in 0..<60 {
            try Task.checkCancellation()
            let webs = visibleWebViews(in: source)
            var loaded = !webs.isEmpty && webs.allSatisfy { !$0.isLoading && $0.url != nil && $0.scrollView.alpha > 0.01 && !$0.scrollView.isDecelerating }
            if loaded {
                for web in webs {
                    let ready: Bool = await withCheckedContinuation { continuation in
                        web.evaluateJavaScript("document.readyState !== 'loading' && (!document.fonts || document.fonts.status === 'loaded')") { result, _ in
                            continuation.resume(returning: result as? Bool ?? false)
                        }
                    }
                    loaded = loaded && ready
                }
            }
            let state = webs.map { "\($0.url?.absoluteString ?? "")|\($0.scrollView.contentOffset)|\($0.bounds.size)" }.joined(separator: ";")
            stable = loaded && state == previous ? stable + 1 : 0
            if stable >= 2 { return }
            previous = state
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CurlError.notReady
    }
    private func snapshot(in source: EPUBNavigatorViewController? = nil) async throws -> UIImage {
        guard let model else { throw CurlError.notReady }
        let webs = visibleWebViews(in: source)
        guard !webs.isEmpty else { throw CurlError.notReady }
        var captures: [(CGRect, UIImage)] = []
        for web in webs {
            web.isOpaque = false; web.underPageBackgroundColor = .clear
            web.superview?.backgroundColor = await model.curlSnapshotBackground(web) ?? .clear
            try Task.checkCancellation()
            let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.afterScreenUpdates = true
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CurlError.notReady) }
                }
            }
            captures.append((web.convert(web.bounds, to: view), image))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = view.window?.screen.scale ?? UIScreen.main.scale; format.opaque = true
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            let bookColor = webs.first?.superview?.backgroundColor
            let followsBook = (bookColor?.cgColor.alpha ?? 0) > 0
            (followsBook ? bookColor! : model.curlPaperColor).setFill(); context.fill(view.bounds)
            if !followsBook, let background = model.curlPaperBackground(size: view.bounds.size) {
                let scale = max(view.bounds.width/background.size.width, view.bounds.height/background.size.height)
                let size = CGSize(width: background.size.width*scale, height: background.size.height*scale)
                background.draw(in: CGRect(x: (view.bounds.width-size.width)/2, y: (view.bounds.height-size.height)/2, width: size.width, height: size.height))
            }
            for (rect, image) in captures { image.draw(in: rect) }
        }
#if DEBUG
        model.curlSnapshotCount += 1
#endif
        return image
    }

    private func requestTurn(forward: Bool) -> Bool {
        guard available, navigator?.currentSelection == nil else { return false }
        guard !turning else { return true }
        guard preparedKey == key, work == nil else {
            queuedDirection = forward; failedKey = nil; refresh(); return true
        }
        guard let target = sheets[forward ? 1 : -1] else { model?.curlReachedBoundary(forward: forward); return true }
        beginTurn(forward: forward)
        guard turning else { return true }
        let direction: UIPageViewController.NavigationDirection = forward != (model?.curlRightToLeft ?? false) ? .forward : .reverse
        pager.setViewControllers([target], direction: direction, animated: true) { [weak self] finished in self?.finishTurn(completed: finished) }
        return true
    }
    private func beginTurn(forward: Bool) {
        guard !turning, let token = model?.beginCurlPreview() else { return }
        transaction = token; turning = true
        preferredForward = forward
        startLookahead(forward: forward)
#if DEBUG
        turnStartedAt = CACurrentMediaTime()
#endif
        model?.curlReady = false
        canvas.blocksTouches = true; pager.view.layer.mask = nil
    }
    private func startLookahead(forward: Bool) {
        guard available, let originKey = preparedKey, originKey == key,
              let configuration = renderingConfiguration, let snapshotNav = snapshotNavigator,
              let target = sheets[forward ? 1 : -1], let model else { return }
        if let ahead, ahead.key == originKey, ahead.forward == forward, ahead.configuration == configuration, !ahead.task.isCancelled { return }
        let previous = ahead?.task
        previous?.cancel()
        let task = Task { @MainActor [weak self] () -> AheadResult? in
            guard let self else { return nil }
            if let previous { _ = await previous.value }
            do {
                try Task.checkCancellation()
                guard self.renderingConfiguration == configuration else { return nil }
                guard let location = try await model.prefetchCurlNeighbor(in: snapshotNav, from: target.location, forward: forward, resetOrigin: previous != nil) else {
                    try Task.checkCancellation()
                    return .boundary
                }
                try await self.waitForPage(in: snapshotNav)
                let image = try await self.snapshot(in: snapshotNav)
                try Task.checkCancellation()
                guard self.renderingConfiguration == configuration else { return nil }
                return .page(ReadiumCurlSheet(slot: forward ? 1 : -1, image: image, location: location))
            } catch { return nil }
        }
        ahead = (originKey, forward, configuration, task)
    }

    private func finishTurn(completed: Bool) {
        guard turning, work == nil, let token = transaction, let model else { return }
        let sheet = pager.viewControllers?.first as? ReadiumCurlSheet
        let target = completed && sheet?.slot != 0 ? sheet?.location : nil
        let warming = ahead
        work = Task { [weak self] in
            guard let self else { return }
            // 正常阅读时已提前完成；快速连续翻页时让预热与卷页动画重叠，避免落页后再串行补拍。
            let extra = target != nil ? await warming?.task.value : nil
            let actual = await model.finishCurlPreview(token, target: target, forward: (sheet?.slot ?? 0) > 0)
#if DEBUG
            if actual != nil, target == nil { model.curlCancelledTurns += 1 }
#endif
            self.transaction = nil; self.turning = false
            self.pager.view.layer.mask = paperMask; self.canvas.blocksTouches = false
            self.work = nil
            if let sheet, sheet.slot != 0, let actual, Self.samePage(actual, sheet.location), let previous = self.sheets[0] {
                let direction = sheet.slot > 0 ? 1 : -1
                if let warming, let extra, warming.key == self.preparedKey,
                   warming.forward == (direction > 0), warming.configuration == self.renderingConfiguration {
                    var pages = [0: ReadiumCurlSheet(slot: 0, image: sheet.image, location: actual),
                                 -direction: ReadiumCurlSheet(slot: -direction, image: previous.image, location: previous.location)]
                    if case .page(let page) = extra { pages[direction] = page }
                    self.ahead = nil; self.carried = nil
                    self.sheets = pages; self.preparedKey = self.key; self.failedKey = nil
                    self.cover.isHidden = true
                    model.curlReady = true
                    if let current = pages[0] { self.pager.setViewControllers([current], direction: .forward, animated: false) }
                    self.recordReadyLatency()
                } else {
                    // 预热失败只回退到原有的一侧补拍；布局已变时连带丢弃旧截图。
                    self.ahead = nil
                    self.carried = self.snapshotConfiguration == self.renderingConfiguration ? (sheet, previous, -direction) : nil
                    self.preparedKey = nil
                    self.cover.image = sheet.image; self.cover.isHidden = false
                    model.curlReady = false
                }
            } else if target != nil {
                self.preparedKey = nil; model.curlReady = false
            } else {
                model.curlReady = true
                if let current = self.sheets[0] { self.pager.setViewControllers([current], direction: .forward, animated: false) }
                self.recordReadyLatency()
            }
            self.refresh()
        }
    }
    private static func samePage(_ lhs: Locator, _ rhs: Locator) -> Bool {
        lhs.href == rhs.href && abs((lhs.locations.progression ?? 0) - (rhs.locations.progression ?? 0)) < 0.0000001
    }
    private func discardSnapshot() {
        ahead?.task.cancel(); ahead = nil
        if let snapshotNavigator {
            snapshotNavigator.willMove(toParent: nil)
            snapshotNavigator.view.removeFromSuperview()
            snapshotNavigator.removeFromParent()
        }
        snapshotNavigator = nil; snapshotConfiguration = nil
    }

    func cancelAndWait() async {
        cancellationDepth += 1
        defer {
            cancellationDepth -= 1
            if cancellationDepth == 0 { DispatchQueue.main.async { [weak self] in self?.refresh() } }
        }
        setPansReady(false)
        queuedDirection = nil
        let background = ahead?.task
        ahead = nil; background?.cancel()
        if let work { if !turning { work.cancel() }; await work.value }
        if turning, let transaction, let model {
            _ = await model.finishCurlPreview(transaction, target: nil)
            self.transaction = nil; turning = false
        }
        if let background { _ = await background.value }
        preparedKey = nil
        carried = nil
        if model?.curlReady == true { model?.curlReady = false }
        discardSnapshot()
        pager.view.layer.mask = paperMask; cover.isHidden = true; spinner.stopAnimating(); canvas.blocksTouches = false
        setPansReady(false)
    }

    private func neighbor(_ controller: UIViewController, after: Bool) -> UIViewController? {
        guard let sheet = controller as? ReadiumCurlSheet, preparedKey == key || turning else { return nil }
        let delta = after != (model?.curlRightToLeft ?? false) ? 1 : -1
        return sheets[sheet.slot + delta]
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? { neighbor(viewController, after: false) }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? { neighbor(viewController, after: true) }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let target = pendingViewControllers.first as? ReadiumCurlSheet else { return }
        beginTurn(forward: target.slot > 0)
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) { finishTurn(completed: completed) }

    @objc private func coldSwipe(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let distance = pan.translation(in: host?.view).x, speed = pan.velocity(in: host?.view).x
        guard abs(distance) > view.bounds.width*0.15 || abs(speed) > 700 else { return }
        _ = requestTurn(forward: (distance < 0) != (model?.curlRightToLeft ?? false))
    }
    // 仅提供卷页 pan 的失败依赖，长按选字与菜单仍交给 WebKit。
    @objc private func longPressObserved(_ press: UILongPressGestureRecognizer) {}
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === coldPan else { return true }
        let speed = coldPan.velocity(in: host?.view)
        return available && navigator?.currentSelection == nil && abs(speed.x) > abs(speed.y)*1.2
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === selectionPress || gestureRecognizer === selectionGate
    }
    

private enum CurlError: Error { case notReady, restore }
}

private final class ReadiumCurlCanvas: UIView {
    var blocksTouches = false
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { blocksTouches && bounds.contains(point) ? self : nil }
}
private final class ReadiumCurlSheet: UIViewController {
    let slot: Int
    let location: Locator
    let image: UIImage
    init(slot: Int, image: UIImage, location: Locator) { self.slot = slot; self.location = location; self.image = image; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() { let imageView = UIImageView(image: image); imageView.contentMode = .scaleToFill; imageView.isUserInteractionEnabled = true; view = imageView }
}
/// 已有选区时阻止卷页识别器，但不取消 WebKit 的选区手柄触摸。
private final class ReadiumCurlSelectionGate: UIGestureRecognizer {
    private let blocked: () -> Bool
    init(blocked: @escaping () -> Bool) { self.blocked = blocked; super.init(target: nil, action: nil) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { state = blocked() ? .began : .failed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { if state == .began { state = .ended } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
