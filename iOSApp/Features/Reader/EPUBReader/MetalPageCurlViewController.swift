import Metal
import MetalKit
import UIKit

/// 基于 Metal 圆柱曲面着色器的共用 3D 仿真翻页控制器（支持 iOS 15+，原生与 Readium 共用）。
/// 静止时暂停并隐藏 `MTKView`，零后台 GPU 开销；拖动或翻页动画期间激活渲染，
/// 并根据 `isDarkMode` 关闭白色镜面高光、仅保留深色折痕投影，避免深色模式下页背泛白。
@MainActor
final class MetalPageCurlViewController: UIViewController, MTKViewDelegate, UIGestureRecognizerDelegate {
    private struct CurlUniforms {
        var aspect: Float
        var axisX: Float
        var axisY: Float
        var axisOffset: Float
        var radius: Float
        var progress: Float
        var isDark: Float
        var backOpacity: Float
        var backColor: SIMD4<Float>
        var isUnderLayer: Float
        var taper: Float
        var padding0: Float = 0
        var padding1: Float = 0
    }

    private struct CurlVertex {
        var uv: SIMD2<Float>
    }

    var isRightToLeft = false
    var isDarkMode = false
    var backPaperColor: UIColor = .systemBackground
    /// 原生引擎静止时由内部 `restingImageView` 展示当前页；Readium 静止时隐藏以露出真实 WebView。
    var showsRestingImage = true

    var canTurnProvider: ((Bool) -> Bool)?
    var onTurnWillBegin: ((Bool) -> Void)?
    var onTurnDidFinish: ((Bool, Bool) -> Void)?

    private(set) lazy var panGesture: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()

    var isAnimating: Bool { isDragging || displayLink != nil }

    private var previousImage: UIImage?
    private var currentImage: UIImage?
    private var nextImage: UIImage?

    private let restingImageView = UIImageView()
    private var metalView: MTKView?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var textureLoader: MTKTextureLoader?
    private var textureCache: [ObjectIdentifier: MTLTexture] = [:]

    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var activeForward = true
    private var curlFromRight = true
    private var progress: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var startProgress: CGFloat = 0
    private var tiltAngle: CGFloat = 0
    private var startTiltAngle: CGFloat = 0
    private var targetTiltAngle: CGFloat = 0
    private var isTapAnimation = false
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.36
    private var displayLink: CADisplayLink?
    private var activeFrontImage: UIImage?
    private var activeUnderImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        restingImageView.contentMode = .scaleToFill
        restingImageView.frame = view.bounds
        restingImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        restingImageView.isHidden = !showsRestingImage
        view.addSubview(restingImageView)
        setupMetal()
        view.addGestureRecognizer(panGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        restingImageView.frame = view.bounds
        metalView?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelActiveAnimation()
    }

    func setImages(previous: UIImage?, current: UIImage?, next: UIImage?) {
        previousImage = previous
        currentImage = current
        nextImage = next
        restingImageView.image = current
        restingImageView.isHidden = !showsRestingImage || isAnimating
        // 清理已不再引用的旧纹理，保持缓存最多 3 张页图并异步预热纹理，消除首次拖动上传卡顿。
        let images = [current, next, previous].compactMap { $0 }
        let liveIDs = Set(images.compactMap { $0.cgImage.map(ObjectIdentifier.init) })
        textureCache = textureCache.filter { liveIDs.contains($0.key) }
        prewarmTextures(for: images)
    }

    private func prewarmTextures(for images: [UIImage]) {
        guard let textureLoader else { return }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let key = ObjectIdentifier(cgImage)
            if textureCache[key] != nil { continue }
            textureLoader.newTexture(cgImage: cgImage, options: options) { [weak self] texture, _ in
                guard let texture else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let currentLive = Set([self.previousImage, self.currentImage, self.nextImage]
                        .compactMap { $0?.cgImage.map(ObjectIdentifier.init) })
                    if currentLive.contains(key) {
                        self.textureCache[key] = texture
                    }
                }
            }
        }
    }

    @discardableResult
    func turn(forward: Bool) -> Bool {
        guard !isAnimating else { return false }
        // 点按翻页模拟老版系统卷页：从下角斜角卷起并平缓扫过全页，而非生硬的 0° 垂直平推。
        let touchYRatio: CGFloat = 0.80
        guard prepareTransition(forward: forward, touchYRatio: touchYRatio, initialProgress: nil) else { return false }
        tiltAngle = curlFromRight ? 0.40 : -0.32
        let endProgress: CGFloat = curlFromRight ? 1.0 : 0.0
        let endTilt: CGFloat = curlFromRight ? 0.14 : -0.10
        startAnimation(to: endProgress, endTilt: endTilt, duration: 0.40, isTap: true)
        return true
    }

    func cancelActiveAnimation() {
        stopDisplayLink()
        isDragging = false
        activeFrontImage = nil
        activeUnderImage = nil
        restingImageView.image = currentImage
        hideMetalOverlay()
    }

    // MARK: - Metal 初始化

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFn = library.makeFunction(name: "pageCurlVertex"),
              let fragmentFn = library.makeFunction(name: "pageCurlFragment") else {
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<CurlVertex>.stride
        descriptor.vertexDescriptor = vertexDescriptor

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDesc) else { return }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline
        self.depthState = depth
        self.textureLoader = MTKTextureLoader(device: device)
        buildGridMesh(device: device, cols: 96, rows: 120)

        let mtk = MTKView(frame: view.bounds, device: device)
        mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.depthStencilPixelFormat = .depth32Float
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtk.isOpaque = false
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.isHidden = true
        mtk.isUserInteractionEnabled = false
        mtk.delegate = self
        view.addSubview(mtk)
        self.metalView = mtk
    }

    private func buildGridMesh(device: MTLDevice, cols: Int, rows: Int) {
        var vertices: [CurlVertex] = []
        vertices.reserveCapacity((cols + 1) * (rows + 1))
        for r in 0...rows {
            let v = Float(r) / Float(rows)
            for c in 0...cols {
                let u = Float(c) / Float(cols)
                vertices.append(CurlVertex(uv: SIMD2<Float>(u, v)))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(cols * rows * 6)
        let stride = UInt32(cols + 1)
        for r in 0..<rows {
            for c in 0..<cols {
                let i0 = UInt32(r) * stride + UInt32(c)
                let i1 = i0 + 1
                let i2 = i0 + stride
                let i3 = i2 + 1
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }
        indexCount = indices.count
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<CurlVertex>.stride, options: .storageModeShared)
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }

    private func texture(for image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage, let textureLoader else { return nil }
        let key = ObjectIdentifier(cgImage)
        if let cached = textureCache[key] { return cached }
        // 禁用 sRGB 隐式转换，保持与 `.bgra8Unorm` 渲染目标一致的色彩空间。
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        guard let tex = try? textureLoader.newTexture(cgImage: cgImage, options: options) else { return nil }
        textureCache[key] = tex
        return tex
    }

    // MARK: - 手势与过渡状态机

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        guard !isAnimating else { return false }
        let hostView = panGesture.view ?? view
        let velocity = panGesture.velocity(in: hostView)
        // 分页模式下拇指弧线滑动常带一定纵向分量，仅排除近纯竖直滑动即可。
        guard abs(velocity.x) > abs(velocity.y) * 0.65 else { return false }
        let dragLeft = velocity.x < 0
        let forward = dragLeft != isRightToLeft
        if let canTurn = canTurnProvider?(forward), !canTurn { return false }
        let targetImage = forward ? nextImage : previousImage
        return currentImage != nil && targetImage != nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let hostView = gesture.view ?? view
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        switch gesture.state {
        case .began:
            guard !isAnimating else { return }
            let vx = gesture.velocity(in: hostView).x
            let dragLeft = vx <= 0
            let forward = dragLeft != isRightToLeft
            let loc = gesture.location(in: view)
            let translation = gesture.translation(in: hostView)
            dragStartPoint = CGPoint(
                x: min(max(loc.x - translation.x, 0), width),
                y: min(max(loc.y - translation.y, 0), height)
            )
            let yRatio = min(max(loc.y / height, 0), 1)
            guard prepareTransition(forward: forward, touchYRatio: yRatio, initialProgress: nil) else {
                gesture.state = .cancelled
                return
            }
            isDragging = true
            updateDragState(location: loc, translation: translation, width: width, height: height)
            metalView?.draw()

        case .changed:
            guard isDragging else { return }
            updateDragState(
                location: gesture.location(in: view),
                translation: gesture.translation(in: hostView),
                width: width,
                height: height
            )
            metalView?.draw()

        case .ended, .cancelled:
            guard isDragging else { return }
            isDragging = false
            let dx = gesture.translation(in: hostView).x
            let vx = gesture.velocity(in: hostView).x
            let threshold = width * 0.18
            let completed: Bool
            if gesture.state == .cancelled {
                completed = false
            } else if abs(vx) > 260 {
                completed = curlFromRight ? (vx < 0) : (vx > 0)
            } else if curlFromRight {
                completed = dx < -threshold || progress > 0.44
            } else {
                completed = dx > threshold || progress < 0.56
            }
            let endProgress: CGFloat = curlFromRight ? (completed ? 1.0 : 0.0) : (completed ? 0.0 : 1.0)
            let endTilt: CGFloat = completed ? tiltAngle * 0.45 : 0
            let releaseDuration: CFTimeInterval = completed
                ? max(0.24, 0.36 - min(Double(abs(vx)), 1600) / 10000)
                : 0.26
            startAnimation(to: endProgress, endTilt: endTilt, duration: releaseDuration, isTap: false)

        default:
            break
        }
    }

    private func updateDragState(location: CGPoint, translation: CGPoint, width: CGFloat, height: CGFloat) {
        let touchX = min(max(location.x, 0), width)
        let touchY = min(max(location.y, 0), height)
        let startYRatio = min(max(dragStartPoint.y / height, 0), 1)
        let touchYRatio = min(max(touchY / height, 0), 1)

        // 右下角上拉使折痕呈 `/`（theta > 0），右上角下拉使折痕呈 `\`（theta < 0），
        // 在保持起手纵向角落倾斜的同时平滑融合二维拖动向量，避免横向滑动时角落倾角塌陷。
        let blendedY = ((touchYRatio * 0.72 + startYRatio * 0.28) - 0.5) * 2.0
        let curvedY = copysign(pow(abs(blendedY), 1.1), blendedY)
        let positionTilt = (curlFromRight ? curvedY : -curvedY) * 0.52
        let dragTilt: CGFloat
        if curlFromRight {
            dragTilt = atan2(-translation.y, max(-translation.x, 32.0))
        } else {
            dragTilt = atan2(translation.y, max(translation.x, 32.0))
        }
        let vectorWeight = min(hypot(translation.x, translation.y) / 64.0, 1.0)
        let rawTilt = positionTilt * 0.85 + dragTilt * 0.60 * vectorWeight
        tiltAngle = min(max(rawTilt, -0.68), 0.68)

        let aspect = Float(width / height)
        let theta = Float(tiltAngle)
        let taper = min(max((curlFromRight ? theta : -theta) / 0.30, -1.0), 1.0)
        let (_, axisX, axisY, dStart, dEnd, radius) = curlGeometry(aspect: aspect, theta: theta, progress: Float(progress), taper: taper)
        let span = max(dStart - dEnd, 0.001)

        // 按翻起纸页外缘（前翻）或可见折痕脊线（后翻）反解轴向偏移，使书页边缘跨过屏幕中线后仍 1:1 紧贴指尖，
        // 避免线性进度在左半屏以 2 倍速冲过手指、在右半屏滞后于手指。
        let finger = SIMD2<Float>(Float(touchX / height), Float(touchY / height))
        let tVec = SIMD2<Float>(-axisY, axisX)
        let center = SIMD2<Float>(aspect * 0.5, 0.5)
        let tHalfSpan = 0.5 * (aspect * abs(tVec.x) + abs(tVec.y))
        let tNorm = min(max(((finger.x - center.x) * tVec.x + (finger.y - center.y) * tVec.y) / max(tHalfSpan, 0.25), -1.0), 1.0)
        let rLocal = max(radius * (1.0 + 0.36 * taper * tNorm), 0.006)
        let piR = Float.pi * rLocal

        if curlFromRight {
            let projected = -(translation.x * cos(tiltAngle) + translation.y * sin(tiltAngle))
            let effectiveDrag = translation.x <= 0 ? max(-translation.x, projected * 0.85) : 0
            guard effectiveDrag > 0 else { progress = 0.005; return }
            let rampDist = min(max((width - dragStartPoint.x) * 0.55, 16), width * 0.22)
            let rampT = Float(min(effectiveDrag / rampDist, 1.0))
            let rampFactor = 1.0 - (1.0 - rampT) * (1.0 - rampT)

            let startEdge = SIMD2<Float>(aspect, finger.y)
            let anchor = startEdge + (finger - startEdge) * rampFactor
            let pAnchor = anchor.x * axisX + anchor.y * axisY
            let dRight = max((aspect - anchor.x) / max(axisX, 0.25), 0)
            let dVert: Float
            if axisY > 0.01 {
                dVert = max((1.0 - anchor.y) / axisY, 0)
            } else if axisY < -0.01 {
                dVert = max(-anchor.y / axisY, 0)
            } else {
                dVert = .greatestFiniteMagnitude
            }
            let dBoundary = min(dRight, dVert)

            let targetAxis: Float
            if dBoundary >= piR {
                targetAxis = pAnchor + 0.5 * (dBoundary - piR)
            } else {
                // 在卷曲半圆范围内用二分求解 s - r*sin(s/r) = dBoundary，保证右半侧起步也紧贴手指。
                var lo: Float = 0
                var hi = piR
                for _ in 0..<8 {
                    let mid = 0.5 * (lo + hi)
                    if mid - rLocal * sin(mid / rLocal) < dBoundary { lo = mid } else { hi = mid }
                }
                let sEdge = 0.5 * (lo + hi)
                targetAxis = pAnchor + dBoundary - sEdge
            }
            progress = CGFloat(min(max((dStart - targetAxis) / span, 0.005), 1.0))
        } else {
            let projected = translation.x * cos(tiltAngle) + translation.y * sin(tiltAngle)
            let effectiveDrag = translation.x >= 0 ? max(translation.x, projected * 0.85) : 0
            guard effectiveDrag > 0 else { progress = 0.995; return }
            let rampDist = min(max(dragStartPoint.x * 0.55, 16), width * 0.22)
            let rampT = Float(min(effectiveDrag / rampDist, 1.0))
            let rampFactor = 1.0 - (1.0 - rampT) * (1.0 - rampT)

            let pFinger = finger.x * axisX + finger.y * axisY
            let targetAxis = dEnd * (1.0 - rampFactor) + (pFinger - rLocal) * rampFactor
            progress = CGFloat(min(max((dStart - targetAxis) / span, 0.0), 0.995))
        }
    }

    private func prepareTransition(forward: Bool, touchYRatio: CGFloat, initialProgress: CGFloat?) -> Bool {
        if let canTurn = canTurnProvider?(forward), !canTurn { return false }
        guard let current = currentImage,
              let target = forward ? nextImage : previousImage else { return false }
        let dragLeft = forward != isRightToLeft
        activeForward = forward
        curlFromRight = dragLeft
        if curlFromRight {
            activeFrontImage = current
            activeUnderImage = target
            progress = initialProgress ?? 0.0
        } else {
            activeFrontImage = target
            activeUnderImage = current
            progress = initialProgress ?? 1.0
        }
        tiltAngle = computeTilt(yRatio: touchYRatio, curlFromRight: curlFromRight)
        onTurnWillBegin?(forward)
        metalView?.isHidden = false
        restingImageView.isHidden = !showsRestingImage
        return true
    }

    private func computeTilt(yRatio: CGFloat, curlFromRight: Bool) -> CGFloat {
        let centered = (yRatio - 0.5) * 2.0
        let curved = copysign(pow(abs(centered), 1.1), centered)
        return (curlFromRight ? curved : -curved) * 0.42
    }

    private func startAnimation(to target: CGFloat, endTilt: CGFloat, duration: CFTimeInterval, isTap: Bool) {
        stopDisplayLink()
        startProgress = progress
        targetProgress = target
        startTiltAngle = tiltAngle
        targetTiltAngle = endTilt
        isTapAnimation = isTap
        animationStartTime = CACurrentMediaTime()
        let minimumDuration: CFTimeInterval = isTap ? 0.32 : 0.14
        animationDuration = max(duration * max(abs(target - startProgress), 0.35), minimumDuration)
        let link = CADisplayLink(target: self, selector: #selector(stepAnimation(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        metalView?.draw()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func stepAnimation(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let rawT = min(max(elapsed / animationDuration, 0), 1)
        let eased: Double
        if isTapAnimation {
            // 点按翻页使用平缓起手、顺滑收尾的 S 型曲线，接近系统 UIPageViewController(.pageCurl) 手感。
            let smooth = rawT * rawT * (3.0 - 2.0 * rawT)
            let easeOut = 1.0 - pow(1.0 - rawT, 2.5)
            eased = smooth * 0.65 + easeOut * 0.35
        } else {
            // 拖动松手衔接指尖速度，用自然减速度收拢。
            eased = 1.0 - pow(1.0 - rawT, 2.8)
        }
        progress = startProgress + (targetProgress - startProgress) * CGFloat(eased)
        tiltAngle = startTiltAngle + (targetTiltAngle - startTiltAngle) * CGFloat(eased)
        metalView?.draw()

        if rawT >= 1.0 {
            stopDisplayLink()
            let completed = curlFromRight ? (targetProgress > 0.5) : (targetProgress < 0.5)
            let forward = activeForward
            // 从左向右回卷时，新页面是展开覆盖在上的 activeFrontImage，而非底层 activeUnderImage。
            if completed {
                let landedImage = curlFromRight ? activeUnderImage : activeFrontImage
                if let landedImage {
                    restingImageView.image = landedImage
                }
            } else {
                restingImageView.image = currentImage
            }
            activeFrontImage = nil
            activeUnderImage = nil
            hideMetalOverlay()
            onTurnDidFinish?(completed, forward)
        }
    }

    private func hideMetalOverlay() {
        metalView?.isHidden = true
        restingImageView.isHidden = !showsRestingImage
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelineState,
              let depthState,
              let commandQueue,
              let vertexBuffer,
              let indexBuffer,
              let frontImg = activeFrontImage,
              let underImg = activeUnderImage,
              let frontTex = texture(for: frontImg),
              let underTex = texture(for: underImg),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        let p = Float(progress)
        let rawTaper = (curlFromRight ? Float(tiltAngle) : Float(-tiltAngle)) / 0.30
        let taper = min(max(rawTaper, -1.0), 1.0)
        let (axisOffset, axisX, axisY, _, _, radius) = curlGeometry(aspect: aspect, theta: Float(tiltAngle), progress: p, taper: taper)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        let resolvedBackColor = backPaperColor.resolvedColor(with: traitCollection)
        if !resolvedBackColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if resolvedBackColor.getWhite(&white, alpha: &a) { r = white; g = white; b = white }
        }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let darkSurface = isDarkMode || luminance < 0.45

        var uniforms = CurlUniforms(
            aspect: aspect,
            axisX: axisX,
            axisY: axisY,
            axisOffset: axisOffset,
            radius: radius,
            progress: p,
            isDark: darkSurface ? 1.0 : 0.0,
            backOpacity: darkSurface ? 0.10 : 0.16,
            backColor: SIMD4<Float>(Float(r), Float(g), Float(b), Float(a)),
            isUnderLayer: 1.0,
            taper: taper
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(frontTex, index: 0)
        encoder.setFragmentTexture(underTex, index: 1)

        // 1. 先绘制底层露出页
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)

        // 2. 再绘制上层卷曲纸页
        uniforms.isUnderLayer = 0.0
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func curlGeometry(aspect: Float, theta: Float, progress p: Float, taper: Float) -> (axisOffset: Float, axisX: Float, axisY: Float, dStart: Float, dEnd: Float, radius: Float) {
        let axisX = cos(theta)
        let axisY = sin(theta)
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(aspect, 0), SIMD2<Float>(0, 1), SIMD2<Float>(aspect, 1)]
        let projections = corners.map { $0.x * axisX + $0.y * axisY }
        let pMin = projections.min() ?? 0
        let pMax = projections.max() ?? aspect
        // 紧致纸张卷径（接近 UIKit pageCurl 的薄纸卷曲感），两端平滑收拢。
        let baseRadius: Float = aspect > 0.75 ? 0.044 : 0.033
        let edgeRamp = min(min(p / 0.07, (1.0 - p) / 0.07), 1.0)
        let radius = max(baseRadius * (0.55 + 0.45 * max(edgeRamp, 0)), 0.008)
        let maxLocalRadius = radius * (1.0 + 0.36 * abs(taper))
        let dStart = pMax
        let dEnd = pMin - (Float.pi * maxLocalRadius) * 0.5 - 0.018
        let axisOffset = dStart + (dEnd - dStart) * p
        return (axisOffset, axisX, axisY, dStart, dEnd, radius)
    }

    // 运行时由 Metal 驱动直接编译着色器，无需在 Xcode 额外安装 MetalToolchain 离线编译组件。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CurlUniforms {
        float aspect;
        float axisX;
        float axisY;
        float axisOffset;
        float radius;
        float progress;
        float isDark;
        float backOpacity;
        float4 backColor;
        float isUnderLayer;
        float taper;
        float padding0;
        float padding1;
    };

    struct CurlVertexIn {
        float2 uv [[attribute(0)]];
    };

    struct CurlVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    inline float localRadius(float2 p, constant CurlUniforms &u) {
        float2 tVec = float2(-u.axisY, u.axisX);
        float2 center = float2(u.aspect * 0.5, 0.5);
        float tHalfSpan = 0.5 * (u.aspect * abs(tVec.x) + abs(tVec.y));
        float tNorm = clamp(dot(p - center, tVec) / max(tHalfSpan, 0.25), -1.0, 1.0);
        return max(u.radius * (1.0 + 0.36 * u.taper * tNorm), 0.006);
    }

    vertex CurlVertexOut pageCurlVertex(
        CurlVertexIn in [[stage_in]],
        constant CurlUniforms &u [[buffer(1)]]
    ) {
        CurlVertexOut out;
        out.uv = in.uv;

        if (u.isUnderLayer > 0.5) {
            float ndcX = in.uv.x * 2.0 - 1.0;
            float ndcY = 1.0 - in.uv.y * 2.0;
            out.position = float4(ndcX, ndcY, 0.9, 1.0);
            return out;
        }

        float2 p = float2(in.uv.x * u.aspect, in.uv.y);
        float2 n = float2(u.axisX, u.axisY);
        float s = dot(p, n) - u.axisOffset;
        float r = localRadius(p, u);
        float piR = M_PI_F * r;

        float2 finalP = p;
        float z = 0.0;

        if (s <= 0.0) {
            finalP = p;
            z = 0.0;
        } else if (s < piR) {
            float alpha = s / r;
            float delta = r * sin(alpha) - s;
            finalP = p + n * delta;
            z = r * (1.0 - cos(alpha));
        } else {
            float delta = -2.0 * s + piR;
            finalP = p + n * delta;
            z = 2.0 * r;
        }

        // 轻微 3D 透视投影：z = 0 处与底图 1:1 像素对齐，抬起的卷页自然向视线前倾。
        float2 center = float2(u.aspect * 0.5, 0.5);
        float focal = 2.4;
        float persp = focal / max(focal - z, 0.6);
        float2 projP = center + (finalP - center) * persp;

        float ndcX = (projP.x / u.aspect) * 2.0 - 1.0;
        float ndcY = 1.0 - projP.y * 2.0;
        float maxZ = max(2.0 * u.radius * 1.4, 0.001);
        float depth = clamp(0.8 - (z / maxZ) * 0.7, 0.05, 0.85);

        out.position = float4(ndcX, ndcY, depth, 1.0);
        return out;
    }

    fragment float4 pageCurlFragment(
        CurlVertexOut in [[stage_in]],
        constant CurlUniforms &u [[buffer(1)]],
        texture2d<float> frontTex [[texture(0)]],
        texture2d<float> underTex [[texture(1)]]
    ) {
        constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        float2 p = float2(in.uv.x * u.aspect, in.uv.y);
        float2 n = float2(u.axisX, u.axisY);
        float r = localRadius(p, u);
        float piR = M_PI_F * r;
        float s = dot(p, n) - u.axisOffset;

        if (u.isUnderLayer > 0.5) {
            float4 base = underTex.sample(texSampler, in.uv);
            float activeMask = smoothstep(0.0, 0.035, u.progress) * (1.0 - smoothstep(0.84, 1.0, u.progress));
            float contactT = clamp((s - r * 0.55) / max(r * 1.45, 0.02), 0.0, 1.0);
            float contact = (1.0 - smoothstep(0.0, 1.0, contactT)) * (u.isDark > 0.5 ? 0.48 : 0.24);
            float ambientW = max(r * 3.6, 0.11);
            float ambientT = clamp((s - r * 0.45) / ambientW, 0.0, 1.0);
            float ambient = (1.0 - smoothstep(0.0, 1.0, ambientT)) * (u.isDark > 0.5 ? 0.22 : 0.14);
            float shadow = clamp(contact + ambient, 0.0, 0.72) * activeMask;
            base.rgb *= (1.0 - shadow);
            return base;
        }

        float4 frontSample = frontTex.sample(texSampler, in.uv);
        float clampedAngle = clamp(s / r, 0.0, M_PI_F);
        float activeMask = smoothstep(0.0, 0.035, u.progress) * (1.0 - smoothstep(0.93, 1.0, u.progress));
        float penumbra = max(r * 1.15, 0.035);

        if (s <= 0.0) {
            // 翻起的纸背悬停在当前页上方，在当前页平面投射柔和阴影，拉开纸页层次感。
            float2 pOrig = p + (piR - 2.0 * s) * n;
            float edgeDist = min(min(pOrig.x, u.aspect - pOrig.x), min(pOrig.y, 1.0 - pOrig.y));
            float flapMask = smoothstep(-penumbra, 0.015, edgeDist);
            float creaseAO = (1.0 - smoothstep(0.0, max(r * 2.4, 0.07), -s)) * (u.isDark > 0.5 ? 0.16 : 0.14);
            float dropShadow = flapMask * ((u.isDark > 0.5 ? 0.09 : 0.075) + creaseAO) * activeMask;
            return float4(frontSample.rgb * (1.0 - dropShadow), frontSample.a);
        } else if (clampedAngle < M_PI_2_F) {
            float2 pOrigCrease = p + piR * n;
            float creaseEdgeDist = min(min(pOrigCrease.x, u.aspect - pOrigCrease.x), min(pOrigCrease.y, 1.0 - pOrigCrease.y));
            float creaseMask = smoothstep(-penumbra, 0.015, creaseEdgeDist);
            float creaseBase = creaseMask * (u.isDark > 0.5 ? 0.25 : 0.215) * activeMask;
            float climb = smoothstep(0.0, 0.65, clampedAngle);
            float shade = mix(1.0 - creaseBase, 1.0, climb);
            float sinA = max(sin(clampedAngle), 0.0);
            float ridge = sin(clamp(clampedAngle / M_PI_2_F, 0.0, 1.0) * M_PI_F);
            float3 sheen = (u.isDark > 0.5 ? float3(0.010) : u.backColor.rgb * 0.028) * ridge * activeMask;
            float turnShade = 1.0 - (u.isDark > 0.5 ? 0.12 : 0.08) * sinA * sqrt(sinA) * activeMask;
            return float4(clamp(frontSample.rgb * shade * turnShade + sheen, 0.0, 1.0), frontSample.a);
        } else {
            float3 backBase = mix(u.backColor.rgb, frontSample.rgb, u.backOpacity);
            float sinA = max(sin(clampedAngle), 0.0);
            float sinPow = sinA * sqrt(sinA);
            float innerT = smoothstep(M_PI_2_F, M_PI_F, clampedAngle);
            float innerDip = sin(innerT * M_PI_F);

            if (u.isDark > 0.5) {
                // 深色模式：关闭白色镜面高光，仅保留折痕弯曲处的柔和立体轮廓
                float3 darkContour = float3(0.026) * sinPow * activeMask;
                float darkHollow = 1.0 - 0.11 * innerDip * activeMask;
                return float4(clamp(backBase * darkHollow + darkContour, 0.0, 1.0), 1.0);
            } else {
                float3 lightSheen = u.backColor.rgb * (0.055 * sinPow * activeMask);
                float hollowShadow = 1.0 - 0.070 * innerDip * activeMask;
                float3 lit = clamp(backBase * hollowShadow + lightSheen, 0.0, 1.0);
                return float4(lit, 1.0);
            }
        }
    }
    """
}
