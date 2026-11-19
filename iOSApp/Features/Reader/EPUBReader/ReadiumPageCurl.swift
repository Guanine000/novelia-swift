// SPDX-License-Identifier: GPL-3.0-only
import Combine
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

/// Readium 宿主拥有的卷页适配器。真实 WebView 保留正文交互，系统卷页只展示有限快照。
/// 宿主另持一个复用同一 Publication 与配置的预取导航器；真实导航器不参与预取。
/// 当前纸面复用真实正文，首方向优先，后台补另一侧及前方一页；取消不移动正文。
@MainActor
final class ReadiumPageCurlController: UIViewController, UIGestureRecognizerDelegate {
    private weak var model: ReadiumEPUBReaderModel?
    private weak var host: UIViewController?
    private weak var navigator: EPUBNavigatorViewController?
    private var snapshotNavigator: EPUBNavigatorViewController?
    private var snapshotConfiguration: String?
    private let canvas = ReadiumCurlCanvas()
    private let cover = UIImageView()
    // 空遮罩只隐藏纸面渲染，不把纸面视图设为不可见，pan 仍可在共同祖先上识别。
    private let paperMask = CALayer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pager = MetalPageCurlViewController()
    private var sheets: [Int: ReadiumCurlSheet] = [:]
    /// 已确认的方向既可能有页面，也可能是边界；未准备的方向绝不能当作书籍边界。
    private var resolvedDirections: Set<Bool> = []
    private var work: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var firstPagePresentation: Task<Bool, Never>?
    /// 首屏检查对应的位置和布局；只有仍匹配时才省略真实正文的重复稳定等待。
    private var firstPresentedKey: String?
    private var enabled = false
    private var isDisappeared = false
    private var isRotating = false
    private var cancellationDepth = 0
    private var preparedKey: String?
    private var failedKey: String?
    /// 屏幕实际展示的页。卷页动画与纸面都以它为准；提交落后时仍保持显示稳定，
    /// 外部导航后由 refresh 重新对齐到已提交位置。
    private var displayLocation: Locator?
    /// 上一次翻页已截好的「落页」和「原当前页」；重建三页时直接复用，少拍两张。
    private var carried: (current: ReadiumCurlSheet, other: ReadiumCurlSheet?, otherSlot: Int)?
    /// 记录已完成 DOM 与字体就绪的 WebView 及其章节 URL，同章翻页跳过重复字体状态查询并缩短稳定采样间隔。
    private let readyWebURLs = NSMapTable<WKWebView, NSString>.weakToStrongObjects()
    /// 缓存当前尺寸、缩放比与阅读外观下的仿真纸面底图（含自定义背景图缩放合成），避免每页截图重复重绘背景大图。
    private var cachedPaperBackdrop: (key: String, image: UIImage)?
#if DEBUG
    private var turnStartedAt: CFTimeInterval?
    /// 上一次翻页再次可操作的时刻；用于测量相邻两段卷页之间的真实间隔。
    private var lastTurnFinishedAt: CFTimeInterval?
#endif
    private func traceInput(_ event: String) {
#if DEBUG
        let entries = ((model?.curlInputTrace ?? "").split(separator: "|").map(String.init) + [event]).suffix(12)
        model?.curlInputTrace = entries.joined(separator: "|")
#endif
    }
    private func recordReadyLatency() {
#if DEBUG
        if let start = turnStartedAt {
            model?.curlTurnReadyMilliseconds = Int((CACurrentMediaTime() - start) * 1000)
            turnStartedAt = nil
        }
        lastTurnFinishedAt = CACurrentMediaTime()
#endif
    }
    private func enqueueTurn(_ forward: Bool) {
        queuedDirections.append(forward)
        if queuedDirections.count > Self.maximumQueuedTurns {
            queuedDirections.removeFirst()
#if DEBUG
            model?.curlInputLost += 1
#endif
        }
        scheduleLoadingIndicatorIfNeeded()
    }
    private func clearQueuedTurns() {
        queuedDirections.removeAll()
        stopLoadingIndicator()
    }
    private func scheduleLoadingIndicatorIfNeeded() {
        guard spinnerTask == nil, work != nil, !queuedDirections.isEmpty, available else { return }
        spinnerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.work != nil, !self.queuedDirections.isEmpty, self.available else { return }
            self.spinner.startAnimating()
        }
    }
    private func stopLoadingIndicator() {
        spinnerTask?.cancel()
        spinnerTask = nil
        spinner.stopAnimating()
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
    /// 繁忙期保留的翻页方向。卷页动画与落页提交必须串行，队列只保证不吞输入；
    /// 超过上限时丢弃最早意图，避免用户停止后仍长时间回放。
    private static let maximumQueuedTurns = 2
    private var queuedDirections: [Bool] = []
    /// 提交队列上限：显示最多领先已提交位置两页；达到上限时暂停新的卷页动画。
    private static let maximumPendingCommits = 2
    private var pendingCommits: [(target: Locator, forward: Bool)] = []
    private var commitTask: Task<Void, Never>?
    private var lastCommitted: Locator?
    private var cancelling = false
    /// 最近一次用户翻页输入与当前动画开始时刻。只有动画期间仍有新输入才继续消费队列，
    /// 用户停手后不再把之前存下的方向逐页播完。
    private var lastInputAt: CFTimeInterval?
    private var turnBeganAt: CFTimeInterval = 0
    /// 卷页动画期间的第二次触摸由被动观察器接管，避免系统 pager 吞掉滑动；
    /// 这段时间 pager pan 与 coldPan 都必须保持关闭，否则同一次手势会被两套识别器重复处理。
    private var burstGestureActive = false
    private var speechObservation: AnyCancellable?
    private var boundPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private lazy var coldPan = UIPanGestureRecognizer(target: self, action: #selector(coldSwipe(_:)))
    private lazy var burstObserver = ReadiumCurlBurstObserver()
    private lazy var selectionGate = ReadiumCurlSelectionGate { [weak self] in self?.navigator?.currentSelection != nil }
    private lazy var selectionPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressObserved(_:)))

    init(model: ReadiumEPUBReaderModel, host: UIViewController, navigator: EPUBNavigatorViewController) {
        self.model = model; self.host = host; self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
        pager.showsRestingImage = true
        pager.isRightToLeft = model.curlRightToLeft
        pager.isDarkMode = model.isDarkMode
        pager.backPaperColor = model.curlPaperColor
        pager.canTurnProvider = { [weak self] forward in
            guard let self else { return false }
            return (self.preparedKey == self.key || self.turning) && self.sheets[forward ? 1 : -1] != nil
        }
        pager.onTurnWillBegin = { [weak self] forward in self?.beginTurn(forward: forward) }
        pager.onTurnDidFinish = { [weak self] completed, forward in
            self?.finishTurn(completed: completed, forward: forward)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = canvas }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager); view.addSubview(pager.view); pager.didMove(toParent: self)
        pager.view.backgroundColor = .clear; pager.view.layer.mask = paperMask
        cover.contentMode = .scaleToFill; cover.isHidden = true; view.addSubview(cover)
        spinner.hidesWhenStopped = true; view.addSubview(spinner)
        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(blockedTap(_:))))
        selectionPress.minimumPressDuration = 0.35
        selectionPress.allowableMovement = 14
        selectionPress.cancelsTouchesInView = false; selectionPress.delegate = self
        coldPan.maximumNumberOfTouches = 1; coldPan.delegate = self
        selectionGate.cancelsTouchesInView = false; selectionGate.delegate = self
        if let host {
            host.view.addGestureRecognizer(coldPan)
            host.view.addGestureRecognizer(selectionGate)
            host.view.addGestureRecognizer(selectionPress)
            // 只观察、不识别：动画期间开启第二次滑动才能在松手时进入队列。
            burstObserver.shouldCapture = { [weak self] in
                guard let self else { return false }
                return self.available && self.turning && !self.coldPan.isEnabled
            }
            burstObserver.onBegan = { [weak self] in self?.setBurstCapture(true) }
            burstObserver.onEnded = { [weak self] dx, dy, duration in
                guard let self else { return }
                self.setBurstCapture(false)
                let speed = duration > 0 ? abs(dx) / CGFloat(duration) : 0
                guard abs(dx) > self.view.bounds.width * 0.12 || speed > 500,
                      abs(dx) > abs(dy) * 1.2 else { return }
                if !self.requestTurn(forward: (dx < 0) != (self.model?.curlRightToLeft ?? false)) {
#if DEBUG
                    self.model?.curlInputLost += 1
#endif
                }
            }
            host.view.addGestureRecognizer(burstObserver)

            host.view.addGestureRecognizer(pager.panGesture)
            pager.panGesture.require(toFail: selectionGate)
            pager.panGesture.require(toFail: selectionPress)
            coldPan.require(toFail: selectionPress)
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
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); isDisappeared = false
        observeFirstPagePresentation()
        refresh()
    }
    /// 真实正文的字体、布局及下一次 WebKit 呈现完成，才算首屏可见；不以卷页缓存就绪代替。
    private func observeFirstPagePresentation() {
        guard firstPagePresentation == nil, let real = navigator else { return }
        MetalPageCurlViewController.prewarmPipelineInBackground()
        firstPagePresentation = Task { [weak self] in
            guard let self else { return false }
            do {
                // 冷启动等待可随时取消，就绪即结束；不能把尚在初始化的 WebKit 按邻页预算误判为失败。
                try await self.waitForPage(in: real, maximumAttempts: 1000)
                try await self.waitForWebPresentation(in: real)
                try Task.checkCancellation()
                self.firstPresentedKey = self.key
#if DEBUG
                self.model?.recordCurlOpeningStage(0)
#endif
                return true
            } catch {
                self.traceInput("first presentation: \(error)")
                return false
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isDisappeared = true
        clearQueuedTurns()
        firstPagePresentation?.cancel(); firstPagePresentation = nil; firstPresentedKey = nil
        ahead?.task.cancel()
        setPansReady(false)
        if !turning { work?.cancel() }
        else if work == nil { pager.cancelActiveAnimation(); finishTurn(completed: false, forward: preferredForward) }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 系统卷页也在旋转；过渡结束前不重建纸面或刷新邻页数据源，避免重入 UIKit 动画。
        isRotating = true
        Task { [weak self] in await self?.cancelAndWait() }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.isRotating = false
            self?.refresh()
        }
    }

    func detach() {
        clearQueuedTurns()
        firstPagePresentation?.cancel(); firstPagePresentation = nil; firstPresentedKey = nil
        enabled = false
        setPansReady(false)
        if !turning { work?.cancel() }
        for gesture in [coldPan, selectionGate, selectionPress, pager.panGesture] as [UIGestureRecognizer] {
            if gesture.view === host?.view { host?.view.removeGestureRecognizer(gesture) }
        }
        model?.onCurlTurn = nil; model?.cancelCurl = nil
        Task { [self] in await cancelAndWait() }
    }

    func configure(enabled: Bool) { self.enabled = enabled; refresh() }

    private var available: Bool {
        enabled && !isDisappeared && !isRotating && cancellationDepth == 0 && model?.status == .ready && model?.speech.isActive == false && navigator?.settings.scroll == false
    }
    private var key: String? {
        guard let model, let location = displayLocation ?? model.locator, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        return "\(model.navigatorRevision)|\((try? location.jsonString()) ?? "")|\(model.curlAppearanceKey)|\(view.bounds.size)|\(view.safeAreaInsets)|\(navigator?.view.bounds.size ?? .zero)"
    }
    private func refresh() {
        guard isViewLoaded, cancellationDepth == 0 else { return }
        // 目录、书签或外部导航改变已提交位置时，显示游标必须跟回真实位置；
        // 卷页动画、准备或后台提交期间不动，否则会把屏幕上的页误当成新位置。
        if !turning, work == nil, commitTask == nil, pendingCommits.isEmpty, displayLocation != model?.locator {
            displayLocation = model?.locator
            preparedKey = nil; failedKey = nil; carried = nil; resolvedDirections = []
            discardSnapshot()
        }
        updatePaperVisibility()
        bindScrollGestures()
        guard available, view.window != nil, let key else {
            if model?.curlReady == true { model?.curlReady = false }
            setPansReady(false)
            if !turning { work?.cancel() }
            else if work == nil { pager.cancelActiveAnimation(); finishTurn(completed: false, forward: preferredForward) }
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
        scheduleLoadingIndicatorIfNeeded()
    }
    private func setPansReady(_ ready: Bool) {
#if DEBUG
        let directions = preparedKey != nil && preparedKey == key
            ? (resolvedDirections.contains(true) ? 1 : 0) + (resolvedDirections.contains(false) ? 2 : 0) : 0
        if model?.curlPreparedDirections != directions { model?.curlPreparedDirections = directions }
#endif
        // 预取恰好在手指滑动途中完成时，不能禁用正在识别的冷手势；否则同一次滑动会被两套识别器同时遗漏。
        let finishingColdGesture = coldPan.numberOfTouches > 0 || coldPan.state == .began || coldPan.state == .changed
        let hasAnyDirection = ready && !resolvedDirections.isEmpty && !finishingColdGesture && !burstGestureActive
        let hasBothDirections = ready && resolvedDirections.count == 2 && !finishingColdGesture && !burstGestureActive
        pager.panGesture.isEnabled = hasAnyDirection && available
        coldPan.isEnabled = available && !hasBothDirections && !burstGestureActive
    }
    /// 只有屏幕页与已提交页一致时才揭开纸面、露出真实 WebView；提交落后时保持纸面，
    /// 否则会先闪回上一页再跳到目标页。
    private func updatePaperVisibility() {
        guard isViewLoaded else { return }
        let aligned: Bool
        if let display = displayLocation, let committed = model?.locator {
            aligned = Self.samePage(display, committed)
        } else {
            aligned = true
        }
        let settled = !turning && aligned && pendingCommits.isEmpty && commitTask == nil
        pager.view.layer.mask = settled ? paperMask : nil
    }
    /// 动画期间第二次触摸由被动观察器独占；不启用 coldPan，避免同一次手势被重复翻页。
    private func setBurstCapture(_ active: Bool) {
        burstGestureActive = active
        if active {
            pager.panGesture.isEnabled = false
            coldPan.isEnabled = false
        } else {
            refresh()
        }
    }
    private func bindScrollGestures() {
        guard let root = navigator?.view else { return }
        func walk(_ view: UIView, insideWeb: Bool) {
            if let scroll = view as? UIScrollView, !boundPans.contains(scroll.panGestureRecognizer) {
                boundPans.add(scroll.panGestureRecognizer)
                scroll.panGestureRecognizer.require(toFail: pager.panGesture)
                scroll.panGestureRecognizer.require(toFail: coldPan)
            }
            let web = insideWeb || view is WKWebView
            view.subviews.forEach { walk($0, insideWeb: web) }
        }
        walk(root, insideWeb: false)
    }

    private func prepare(key: String) async {
        guard let model, let host, let real = navigator else { work = nil; return }
        // 显示可能领先于真实导航器；准备会截取真实当前页，必须先收敛到屏幕上的页。
        guard await drainCurlCommits() else {
            work = nil
            if let session = transaction { model.endCurlPreview(session) }
            transaction = nil
            displayLocation = model.locator
            preparedKey = nil; failedKey = nil; carried = nil; resolvedDirections = []
            model.curlReady = false
            refresh()
            return
        }
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
        if snapshotConfiguration != configuration { carried = nil; resolvedDirections = []; discardSnapshot() }
        let reused = snapshotNavigator != nil
        let snapshotNav: EPUBNavigatorViewController
        do {
            if let existing = snapshotNavigator { snapshotNav = existing }
            else {
                // 先让真实正文完成首次呈现，再创建第二套 WebView，避免预热抢占首屏加载与排版。
                observeFirstPagePresentation()
                let presented = await firstPagePresentation?.value ?? false
                try Task.checkCancellation()
                guard presented else {
                    firstPagePresentation = nil
                    throw CurlError.notReady
                }
                guard available, model.navigator === real, key == self.key else { throw CancellationError() }
                guard let created = try model.makeCurlSnapshotNavigator() else { work = nil; return }
                snapshotNav = created
#if DEBUG
                model.recordCurlOpeningStage(1)
#endif
                snapshotNavigator = created; snapshotConfiguration = configuration
                host.addChild(created)
                host.view.insertSubview(created.view, belowSubview: real.view)
                created.view.frame = real.view.frame
                // 真实正文有透明区域，预取层不能从后面露出；遮罩不影响 WebKit 的内容快照。
                created.view.layer.mask = CALayer()
                created.view.isUserInteractionEnabled = false
                created.didMove(toParent: host)
            }
        } catch {
            work = nil
            if error is CancellationError || Task.isCancelled {
                if available { refresh() }
            } else {
                failedKey = key
                model.curlError = "正文尚未完成呈现，请稍后重试仿真翻页。"
            }
            return
        }
        guard let token = model.beginCurlPreview(snapshot: snapshotNav) else { work = nil; return }
        transaction = token
        // 独立预取不遮住已可阅读的正文；第一次点按和滑动仍可进入排队入口。
        canvas.blocksTouches = false
        let carry = carried
        carried = nil
        var phase = "origin"
        var result: [Int: ReadiumCurlSheet] = [:]
        if let carry {
            result[0] = ReadiumCurlSheet(slot: 0, image: carry.current.image, location: carry.current.location)
            if let other = carry.other { result[carry.otherSlot] = ReadiumCurlSheet(slot: carry.otherSlot, image: other.image, location: other.location) }
        } else { resolvedDirections = [] }
        // 首次只准备队首方向；其余方向在同一后台工作流补齐后按序执行。
        let firstDirection = queuedDirections.first ?? preferredForward
        preferredForward = firstDirection
#if DEBUG
        // 同一独立验证包内交错采样串行基线，隔离模拟器冷热与运行负载变化；Release 固定分批准备。
        let directionCount = model.validatesPagination && ProcessInfo.processInfo.arguments.contains("-architectureCurlSerialBaseline") ? 2 : 1
#else
        let directionCount = 1
#endif
        let gaps = [firstDirection, !firstDirection].filter { !resolvedDirections.contains($0) }.prefix(directionCount)
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
                if let current = result[0] { cover.image = current.image; cover.isHidden = true }
            } else {
                let alreadyPresented = firstPresentedKey == key
                if !alreadyPresented { try await waitForPage(in: real) }
                guard available, key == self.key else { throw CancellationError() }
                guard let origin = model.locator else { throw CurlError.notReady }
                // 首屏刚通过 waitForWebPresentation(afterScreenUpdates: true) 屏障，跳过第二次强制提交可减少首屏准备耗时。
                let current = try await snapshot(in: real, afterScreenUpdates: !alreadyPresented)
                result[0] = ReadiumCurlSheet(slot: 0, image: current, location: origin)
                cover.image = current; cover.isHidden = true
                model.warmAdjacentChapterAnnotations(around: origin)
            }
            for forward in gaps {
                try Task.checkCancellation()
                guard available, key == self.key else { throw CancellationError() }
                phase = forward ? "next" : "previous"
                if let origin = result[0]?.location, model.isAtCurlBookBoundary(origin, forward: forward) {
                    resolvedDirections.insert(forward)
                    continue
                }
                try await waitForPage(in: snapshotNav)
                if let location = try await model.previewCurlNeighbor(forward: forward, transaction: token) {
                    try await waitForPage()
                    result[forward ? 1 : -1] = ReadiumCurlSheet(slot: forward ? 1 : -1, image: try await snapshot(), location: location)
                }
                resolvedDirections.insert(forward)
                if forward != gaps.last {
                    guard await model.restoreCurlPreview(token) else { throw CurlError.restore }
                    try await waitForPage(in: snapshotNav)
                }
            }
            try Task.checkCancellation()
            guard available, key == self.key else { throw CancellationError() }
            let finished = await model.finishCurlPreview(token, target: nil)
            transaction = nil
            guard finished != nil else { throw CurlError.restore }

            displayLocation = result[0]?.location
            sheets = result; preparedKey = key; failedKey = nil
            model.curlReady = key == self.key
            if model.curlReady {
                recordReadyLatency()
#if DEBUG
                model.recordCurlOpeningStage(2)
                if resolvedDirections.count == 2 { model.recordCurlOpeningStage(3) }
#endif
            }
            syncPagerSheets()
        } catch {
            let cleanup = Task { @MainActor in await model.finishCurlPreview(token, target: nil) }
            _ = await cleanup.value
            transaction = nil; preparedKey = nil
            model.curlReady = false
            // 仅位置键瞬时变化时复用已加载的影子视图，下轮会显式恢复新原点；布局变化或离开仍丢弃。
            let canReuse = (error is CancellationError || Task.isCancelled) && available
                && model.navigator === real && snapshotConfiguration == renderingConfiguration
            if !canReuse { discardSnapshot() }
            if !(error is CancellationError), !Task.isCancelled, key == self.key {
#if DEBUG
                model.curlPreparationFailure = "\(phase): \(error)"
#endif
                failedKey = key
                model.curlError = "暂时无法准备仿真翻页，请重试或切换为跟手平移。"
                // 失败后不再回放旧手势，避免用户停止操作几秒后突然继续翻页。
                clearQueuedTurns()
            }
        }
        traceInput("prepared queue=\(queuedDirections) match=\(preparedKey == self.key) cancelled=\(Task.isCancelled)")
        work = nil; stopLoadingIndicator(); cover.isHidden = true; canvas.blocksTouches = false
        if !available { discardSnapshot() }
        setPansReady(preparedKey == self.key)
        updatePaperVisibility()

        // 布局键短暂变化后可能又回到原值；取消的准备也必须重新检查当前缓存，不能丢失最后一次唤醒。
        guard !Task.isCancelled else {
            if available { refresh() }
            return
        }
        if model.curlReady { startLookahead(forward: preferredForward) }
        if !performQueuedTurn(), available, preparedKey == nil || preparedKey != self.key { refresh() }
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
    private func waitForWebPresentation(in source: EPUBNavigatorViewController) async throws {
        for web in visibleWebViews(in: source) {
            try Task.checkCancellation()
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            config.afterScreenUpdates = true
            let _: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CurlError.notReady) }
                }
            }
        }
    }
    private func waitForPage(in source: EPUBNavigatorViewController? = nil, maximumAttempts: Int = 180) async throws {
        var previous = "", stable = 0
        for _ in 0..<maximumAttempts {
            try Task.checkCancellation()
            let webs = visibleWebViews(in: source)
            var loaded = !webs.isEmpty && webs.allSatisfy { !$0.isLoading && $0.url != nil && $0.scrollView.alpha > 0.01 && !$0.scrollView.isDecelerating }
            if loaded {
                for web in webs {
                    let urlKey = web.url?.absoluteString ?? ""
                    if !urlKey.isEmpty, (readyWebURLs.object(forKey: web) as String?) == urlKey {
                        continue
                    }
                    let ready: Bool = await withCheckedContinuation { continuation in
                        web.evaluateJavaScript("document.readyState !== 'loading' && (!document.fonts || document.fonts.status === 'loaded')") { result, _ in
                            continuation.resume(returning: result as? Bool ?? false)
                        }
                    }
                    if ready, !urlKey.isEmpty {
                        readyWebURLs.setObject(urlKey as NSString, forKey: web)
                    }
                    loaded = loaded && ready
                }
            }
            let state = webs.map { "\($0.url?.absoluteString ?? "")|\($0.scrollView.contentOffset)|\($0.bounds.size)" }.joined(separator: ";")
            stable = loaded && state == previous ? stable + 1 : 0
            if stable >= 2 { return }
            previous = state
            try await Task.sleep(nanoseconds: loaded ? 6_000_000 : 12_000_000)
        }
        throw CurlError.notReady
    }
    private func paperBackdrop(model: ReadiumEPUBReaderModel, scale: CGFloat, bookColor: UIColor?) -> UIImage {
        let size = view.bounds.size
        let followsBook = (bookColor?.cgColor.alpha ?? 0) > 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if followsBook { bookColor?.getRed(&r, green: &g, blue: &b, alpha: &a) }
        let colorKey = followsBook ? "\(r),\(g),\(b),\(a)" : "paper"
        let key = "\(size)|\(scale)|\(model.curlAppearanceKey)|\(colorKey)"
        if let cached = cachedPaperBackdrop, cached.key == key {
            return cached.image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let backdrop = UIGraphicsImageRenderer(size: size, format: format).image { context in
            (followsBook ? bookColor! : model.curlPaperColor).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if !followsBook, let background = model.curlPaperBackground(size: size) {
                let bgScale = max(size.width / background.size.width, size.height / background.size.height)
                let drawSize = CGSize(width: background.size.width * bgScale, height: background.size.height * bgScale)
                background.draw(in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
            }
        }
        cachedPaperBackdrop = (key, backdrop)
        return backdrop
    }
    private func snapshot(in source: EPUBNavigatorViewController? = nil, afterScreenUpdates: Bool = true) async throws -> UIImage {
        guard let model else { throw CurlError.notReady }
        let webs = visibleWebViews(in: source)
        guard !webs.isEmpty else { throw CurlError.notReady }
        var captures: [(CGRect, UIImage)] = []
        for web in webs {
            web.isOpaque = false; web.underPageBackgroundColor = .clear
            web.superview?.backgroundColor = await model.curlSnapshotBackground(web) ?? .clear
            try Task.checkCancellation()
            let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.afterScreenUpdates = afterScreenUpdates
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CurlError.notReady) }
                }
            }
            captures.append((web.convert(web.bounds, to: view), image))
        }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let bookColor = webs.first?.superview?.backgroundColor
        let backdrop = paperBackdrop(model: model, scale: scale, bookColor: bookColor)
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            backdrop.draw(at: .zero)
            for (rect, image) in captures { image.draw(in: rect) }
        }
#if DEBUG
        model.curlSnapshotCount += 1
        if source === navigator { model.curlLiveSnapshotCount += 1 }
#endif
        return image
    }

    private func requestTurn(forward: Bool, isReplay: Bool = false) -> Bool {
        traceInput("turn f=\(forward) available=\(available) turning=\(turning) match=\(preparedKey == key) work=\(work != nil) sheets=\(sheets.keys.sorted())")
        guard available, navigator?.currentSelection == nil else { return false }
        // 回放排队方向不算新的用户输入，否则停手后的队列会被自己续命。
        if !isReplay { lastInputAt = CACurrentMediaTime() }
        guard !turning else { enqueueTurn(forward); return true }
        // 首个真实 Locator 尚未到达时两个键都为 nil，不代表已经准备好，必须保留首次操作。
        guard let key, preparedKey == key, work == nil else {
            enqueueTurn(forward); failedKey = nil; refresh(); return true
        }
        guard resolvedDirections.contains(forward) else {
            // 缺少的方向按需提升为前台准备，保留已截好的当前页和另一侧，不吞掉首次反向操作。
            enqueueTurn(forward)
            if let current = sheets[0] { carried = (current, sheets[forward ? -1 : 1], forward ? -1 : 1) }
            preparedKey = nil
            model?.curlReady = false
            refresh()
            return true
        }
        // 提交管道已满时不再开始新动画，避免显示无限领先、退出时回退过多。
        guard pendingCommits.count < Self.maximumPendingCommits else { enqueueTurn(forward); return true }
        guard sheets[forward ? 1 : -1] != nil else { model?.curlReachedBoundary(forward: forward); return true }
        _ = pager.turn(forward: forward)
        return true
    }
    private func beginTurn(forward: Bool) {
        guard !turning else { traceInput("begin rejected busy=\(model?.curlBusy ?? false)"); return }
        // 连续翻页复用同一会话：提交在后台逐页追赶，动画不再等上一页 go + settle。
        let token: UUID
        if let active = model?.activeCurlPreview {
            token = active
        } else if let created = model?.beginCurlPreview() {
            token = created
        } else {
            traceInput("begin rejected busy=\(model?.curlBusy ?? false)")
            return
        }
        transaction = token; turning = true
        turnBeganAt = CACurrentMediaTime()
        preferredForward = forward
#if DEBUG
        if let previous = lastTurnFinishedAt {
            model?.curlBetweenTurnsMilliseconds = Int((CACurrentMediaTime() - previous) * 1000)
            lastTurnFinishedAt = nil
        }
#endif
        // 用户已经翻向就绪侧，旧页的另一侧将被原当前页替代，不再等待无用的反向补齐。
        if resolvedDirections.count < 2 { ahead?.task.cancel() }
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
              let origin = sheets[0], let model else { return }
        let target = sheets[forward ? 1 : -1]
        if let ahead, ahead.key == originKey, ahead.forward == forward, ahead.configuration == configuration, !ahead.task.isCancelled { return }
        let previous = ahead?.task
        previous?.cancel()
        let task = Task { @MainActor [weak self] () -> AheadResult? in
            guard let self else { return nil }
            // 上一轮预热正常结束时，影子导航器已停在本次目标页；由 prefetch 的位置比对决定
            // 是否回位即可。只有上一轮被取消/失败导致落点不明时才强制回位，避免每页多一次
            // go + 稳定采样。
            var previousLanded = true
            if let previous { previousLanded = (await previous.value) != nil }
            do {
                try Task.checkCancellation()
                guard self.available, self.renderingConfiguration == configuration, originKey == self.key else { return nil }
                var filledSide = false
                for side in [!forward, forward] where !self.resolvedDirections.contains(side) {
                    if self.turning { break }
#if DEBUG
                    // 独立夹具注入慢速反向准备，验证未就绪方向的首次输入及取消；生产构建不包含此等待。
                    if model.validatesPagination, ProcessInfo.processInfo.arguments.contains("-architectureCurlSlowOpposite") {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
#endif
                    var page: ReadiumCurlSheet?
                    let movedSnapshot: Bool
                    if model.isAtCurlBookBoundary(origin.location, forward: side) {
                        // 全书首章首页的反向已明确为边界，不再把影子导航器拉回首页再跳回目标页，保留在 target 位置直接继续向后预热。
                        try await Task.sleep(nanoseconds: 2_000_000)
                        movedSnapshot = false
                    } else {
                        let location = try await model.prefetchCurlNeighbor(in: snapshotNav, from: origin.location, forward: side, resetOrigin: filledSide || !previousLanded)
                        if let location {
                            try await self.waitForPage(in: snapshotNav)
                            page = ReadiumCurlSheet(slot: side ? 1 : -1, image: try await self.snapshot(in: snapshotNav), location: location)
                        }
                        movedSnapshot = true
                    }
                    try Task.checkCancellation()
                    guard self.available, self.renderingConfiguration == configuration else { return nil }
                    if !self.turning, originKey == self.preparedKey, originKey == self.key {
                        self.sheets[side ? 1 : -1] = page
                        self.resolvedDirections.insert(side)
                        self.syncPagerSheets()
#if DEBUG
                        if self.resolvedDirections.count == 2 { model.recordCurlOpeningStage(3) }
#endif
                        self.setPansReady(true)
                    }
                    if movedSnapshot { filledSide = true }
                }
                guard let target else { return .boundary }
                guard let location = try await model.prefetchCurlNeighbor(in: snapshotNav, from: target.location, forward: forward, resetOrigin: filledSide || !previousLanded) else {
                    try Task.checkCancellation()
                    return .boundary
                }
                try await self.waitForPage(in: snapshotNav)
                let image = try await self.snapshot(in: snapshotNav)
                try Task.checkCancellation()
                guard self.available, self.renderingConfiguration == configuration else { return nil }
                return .page(ReadiumCurlSheet(slot: forward ? 1 : -1, image: image, location: location))
            } catch { return nil }
        }
        ahead = (originKey, forward, configuration, task)
    }

    private func syncPagerSheets() {
        pager.isRightToLeft = model?.curlRightToLeft ?? false
        pager.isDarkMode = model?.isDarkMode ?? false
        pager.backPaperColor = model?.curlPaperColor ?? .systemBackground
        pager.setImages(previous: sheets[-1]?.image, current: sheets[0]?.image, next: sheets[1]?.image)
    }

    private func finishTurn(completed: Bool, forward: Bool) {
        guard turning, work == nil, transaction != nil, let model else { return }
        let sheet = completed ? sheets[forward ? 1 : -1] : sheets[0]
        let target = completed && sheet?.slot != 0 ? sheet?.location : nil
        let warming = ahead
        // 动画已结束、正式页面仍在定位时，使用冷手势接收下一次操作，避免丢弃请求。
        setPansReady(false)
        work = Task { [weak self] in
            guard let self else { return }
            // 正常阅读时已提前完成；快速连续翻页时让预热与卷页动画重叠，避免落页后再串行补拍。
            let extra = target != nil ? await warming?.task.value : nil
            if self.cancelling {
                self.turning = false; self.work = nil
                self.canvas.blocksTouches = false
                self.syncPagerSheets()
                self.updatePaperVisibility()
                return
            }
            self.turning = false
            self.canvas.blocksTouches = false
            self.work = nil
            guard let sheet, let target, sheet.slot != 0 else {
                // 取消：不提交，纸面回到当前页。
#if DEBUG
                model.curlCancelledTurns += 1
#endif
                model.curlReady = true
                self.syncPagerSheets()
                self.recordReadyLatency()
                self.refresh(); self.performQueuedTurn(); self.endSessionIfIdle()
                return
            }
            let direction = sheet.slot > 0 ? 1 : -1
            let previous = self.sheets[0]
            self.displayLocation = target
            var pages = [0: ReadiumCurlSheet(slot: 0, image: sheet.image, location: target)]
            if let previous {
                pages[-direction] = ReadiumCurlSheet(slot: -direction, image: previous.image, location: previous.location)
            }
            var resolved: Set<Bool> = [direction < 0]
            switch extra {
            case .page(let page)?:
                pages[direction] = page; resolved.insert(direction > 0)
            case .boundary?:
                resolved.insert(direction > 0)
            case nil:
                break
            }
            self.ahead = nil; self.carried = nil
            self.sheets = pages; self.resolvedDirections = resolved
            self.preparedKey = self.key; self.failedKey = nil
            self.cover.isHidden = true
            model.curlReady = true
            self.syncPagerSheets()
            self.recordReadyLatency()
            // 视觉立即前移；真实导航器在后台按顺序追赶。提交失败时再回退。
            self.pendingCommits.append((target, direction > 0))
            self.startCommitWorker()
            self.refresh()
            self.performQueuedTurn()
        }
    }
    /// 串行提交真实导航器；提交期间不阻塞下一段卷页动画。
    private func startCommitWorker() {
        guard commitTask == nil, let session = transaction, let model else { return }
        commitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let item = self.pendingCommits.first {
                if self.cancelling { break }
                guard let actual = await model.commitCurlPreview(session, target: item.target, forward: item.forward) else {
                    self.commitTask = nil
                    self.failCommit()
                    return
                }
                self.pendingCommits.removeFirst()
                self.lastCommitted = actual
                self.updatePaperVisibility()
                self.performQueuedTurn()
            }
            self.commitTask = nil
            // 揭开纸面前确认真实页排版与 WebKit 合成均已提交，避免露出尚未完成渲染的中间帧。
            if !self.turning, self.pendingCommits.isEmpty, let navigator = self.navigator {
                try? await self.waitForPage(in: navigator, maximumAttempts: 50)
                if !self.turning, !self.cancelling, self.pendingCommits.isEmpty {
                    try? await self.waitForWebPresentation(in: navigator)
                }
            }
            self.updatePaperVisibility()
            self.endSessionIfIdle()
        }
    }
    private func endSessionIfIdle() {
        guard !turning, work == nil, commitTask == nil,
              pendingCommits.isEmpty, queuedDirections.isEmpty,
              let session = transaction else { return }
        model?.endCurlPreview(session)
        transaction = nil
        updatePaperVisibility()
    }
    /// 提交失败：停掉流水线，回到最后一个已提交页并重新准备，不让阅读器进入 failed。
    private func failCommit() {
        pendingCommits.removeAll()
        clearQueuedTurns()
        if let session = transaction { model?.endCurlPreview(session) }
        transaction = nil
        displayLocation = model?.locator
        preparedKey = nil; carried = nil; resolvedDirections = []
        discardSnapshot()
        model?.curlError = "暂时无法提交翻页位置，请稍后重试。"
        refresh()
    }
    /// 准备或取消前把显示页提交到真实导航器；提交失败时返回 false，由调用方回退。
    @discardableResult
    private func drainCurlCommits() async -> Bool {
        if let commitTask { await commitTask.value }
        guard let session = transaction, let model else { return true }
        if let target = displayLocation, model.locator == nil || !Self.samePage(target, model.locator!) {
            guard await model.commitCurlPreview(session, target: target, forward: true) != nil else { return false }
        }
        model.endCurlPreview(session)
        transaction = nil
        pendingCommits.removeAll()
        return true
    }
    /// 每次落页只消费一个方向，剩余请求留到下一次落页；返回是否真的发起了翻页。
    @discardableResult
    private func performQueuedTurn() -> Bool {
        guard !queuedDirections.isEmpty else { return false }
        // 用户停手后不再回放旧方向：只有当前动画期间仍收到新输入才继续。
        guard let lastInputAt, lastInputAt > turnBeganAt else { clearQueuedTurns(); return false }
        guard let direction = queuedDirections.first, let key, available, !turning, work == nil,
              pendingCommits.count < Self.maximumPendingCommits, preparedKey == key else { return false }
        queuedDirections.removeFirst()
        _ = requestTurn(forward: direction, isReplay: true)
        return true
    }
    // 纸面只在动画与落页期间接管触摸，此时也必须保留用户的下一次操作。
    @objc private func blockedTap(_ tap: UITapGestureRecognizer) {
        guard available, tap.state == .ended else { return }
        let action = ReaderTapZoneMode.current.action(
            at: tap.location(in: view),
            in: view.bounds.size,
            isRightToLeft: model?.curlRightToLeft ?? false
        )
        switch action {
        case .menu:
            model?.onCenterTap()
        case .next, .previous:
            _ = requestTurn(forward: action == .next)
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
        readyWebURLs.removeAllObjects()
        cachedPaperBackdrop = nil
    }

    func cancelAndWait() async {
        cancellationDepth += 1
        cancelling = true
        defer {
            cancelling = false
            cancellationDepth -= 1
            if cancellationDepth == 0 { DispatchQueue.main.async { [weak self] in self?.refresh() } }
        }
        setPansReady(false)
        clearQueuedTurns()
        // 首屏等待也是可取消工作，旋转或设置变更不能等待完整的冷启动预算。
        firstPagePresentation?.cancel(); firstPagePresentation = nil; firstPresentedKey = nil
        let background = ahead?.task
        ahead = nil; background?.cancel()
        if let work { if !turning { work.cancel() }; await work.value }
        if let commitTask { await commitTask.value }
        // 只有显示领先时才在取消前补提交；显示与已提交一致时保持真实导航器原状，
        // 由 Readium 自己处理旋转/重排，避免把逻辑位置重新解析成另一方向的分页起点。
        if let session = transaction, let model, let target = displayLocation,
           !pendingCommits.isEmpty || model.locator == nil || !Self.samePage(target, model.locator!) {
            _ = await model.commitCurlPreview(session, target: target, forward: true)
        }
        if let session = transaction { model?.endCurlPreview(session) }
        self.transaction = nil; turning = false
        pager.cancelActiveAnimation()
        pendingCommits.removeAll()
        if let background { _ = await background.value }
        preparedKey = nil
        displayLocation = nil
        carried = nil; resolvedDirections = []; firstPresentedKey = nil
        if model?.curlReady == true { model?.curlReady = false }
        discardSnapshot()
        pager.view.layer.mask = paperMask; cover.isHidden = true; stopLoadingIndicator(); canvas.blocksTouches = false
        updatePaperVisibility()
        setPansReady(false)
    }

    @objc private func coldSwipe(_ pan: UIPanGestureRecognizer) {
        if pan.state != .changed { traceInput("cold=\(pan.state.rawValue) dx=\(Int(pan.translation(in: host?.view).x))") }
        guard pan.state == .ended || pan.state == .cancelled else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
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
        traceInput("begin available=\(available) selection=\(navigator?.currentSelection != nil) vx=\(Int(speed.x)) vy=\(Int(speed.y))")
        guard available, !turning, navigator?.currentSelection == nil, abs(speed.x) > abs(speed.y)*1.2 else { return false }
        let forward = (speed.x < 0) != (model?.curlRightToLeft ?? false)
        // 已有该方向纸面且纸面跟手手势已启用时，让位给 pager.panGesture 实时跟手卷曲；仅缺失方向走 coldPan。
        if pager.panGesture.isEnabled, preparedKey == key, sheets[forward ? 1 : -1] != nil { return false }
        return true
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
/// 只观察卷页动画期间的触摸，不进入识别状态、不参与手势竞争。
/// 系统 pageCurl 动画运行时 pager 的 pan 仍会接管新触摸但不会翻页；这里在松手后
/// 把第二、第三次滑动交回控制器排队，避免动画窗口内的输入被 UIKit 静默丢弃。
private final class ReadiumCurlBurstObserver: UIGestureRecognizer {
    var shouldCapture: (() -> Bool)?
    var onBegan: (() -> Void)?
    var onEnded: ((CGFloat, CGFloat, TimeInterval) -> Void)?
    private var start: CGPoint?
    private var last: CGPoint?
    private var startedAt: TimeInterval?
    private var capturing = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !capturing, let touch = touches.first, shouldCapture?() == true else { return }
        capturing = true
        start = touch.location(in: view); last = start; startedAt = touch.timestamp
        onBegan?()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard capturing, let touch = touches.first else { return }
        last = touch.location(in: view)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches.first)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches.first)
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func reset() {
        super.reset()
        capturing = false; start = nil; last = nil; startedAt = nil
    }
    private func finish(_ touch: UITouch?) {
        guard capturing else { return }
        capturing = false
        let origin = start ?? .zero
        let end = touch?.location(in: view) ?? last ?? origin
        let duration = max((touch?.timestamp ?? 0) - (startedAt ?? 0), 0.001)
        start = nil; last = nil; startedAt = nil
        onEnded?(end.x - origin.x, end.y - origin.y, duration)
    }
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
