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
    private var activeForward = true
    private var curlFromRight = true
    private var progress: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var startProgress: CGFloat = 0
    private var tiltAngle: CGFloat = 0
    private var startTiltAngle: CGFloat = 0
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.26
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
        // 清理已不再引用的旧纹理，保持缓存最多 3 张页图。
        let liveIDs = Set([previous, current, next].compactMap { $0?.cgImage.map(ObjectIdentifier.init) })
        textureCache = textureCache.filter { liveIDs.contains($0.key) }
    }

    @discardableResult
    func turn(forward: Bool) -> Bool {
        guard !isAnimating else { return false }
        guard prepareTransition(forward: forward, touchYRatio: 0.5, initialProgress: nil) else { return false }
        startAnimation(to: curlFromRight ? 1.0 : 0.0, duration: 0.30)
        return true
    }

    func cancelActiveAnimation() {
        stopDisplayLink()
        isDragging = false
        activeFrontImage = nil
        activeUnderImage = nil
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
        buildGridMesh(device: device, cols: 72, rows: 96)

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
        let velocity = panGesture.velocity(in: view)
        // 仅拦截横向为主的手势，避免干扰纵向交互。
        guard abs(velocity.x) > abs(velocity.y) * 1.1 else { return false }
        let dragLeft = velocity.x < 0
        let forward = dragLeft != isRightToLeft
        if let canTurn = canTurnProvider?(forward), !canTurn { return false }
        let targetImage = forward ? nextImage : previousImage
        return currentImage != nil && targetImage != nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        switch gesture.state {
        case .began:
            guard !isAnimating else { return }
            let vx = gesture.velocity(in: view).x
            let dragLeft = vx <= 0
            let forward = dragLeft != isRightToLeft
            let yRatio = min(max(gesture.location(in: view).y / height, 0), 1)
            guard prepareTransition(forward: forward, touchYRatio: yRatio, initialProgress: nil) else {
                gesture.state = .cancelled
                return
            }
            isDragging = true
            metalView?.draw()

        case .changed:
            guard isDragging else { return }
            let dx = gesture.translation(in: view).x
            let delta = abs(dx) / width
            if curlFromRight {
                // 向左拉：progress 从 0 增至 1
                progress = dx < 0 ? min(max(delta, 0), 1) : 0
            } else {
                // 向右拉：progress 从 1 降至 0
                progress = dx > 0 ? min(max(1 - delta, 0), 1) : 1
            }
            let yRatio = min(max(gesture.location(in: view).y / height, 0), 1)
            tiltAngle = computeTilt(yRatio: yRatio)
            metalView?.draw()

        case .ended, .cancelled:
            guard isDragging else { return }
            isDragging = false
            let dx = gesture.translation(in: view).x
            let vx = gesture.velocity(in: view).x
            let threshold = width * 0.22
            let completed: Bool
            if gesture.state == .cancelled {
                completed = false
            } else if curlFromRight {
                completed = dx < -threshold || vx < -550
            } else {
                completed = dx > threshold || vx > 550
            }
            let endProgress: CGFloat = curlFromRight ? (completed ? 1.0 : 0.0) : (completed ? 0.0 : 1.0)
            startAnimation(to: endProgress, duration: 0.24)

        default:
            break
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
        tiltAngle = computeTilt(yRatio: touchYRatio)
        onTurnWillBegin?(forward)
        metalView?.isHidden = false
        restingImageView.isHidden = true
        return true
    }

    private func computeTilt(yRatio: CGFloat) -> CGFloat {
        // 手指靠近上下角时纸张微斜（最大约 14°），中间水平拉动时保持水平。
        let centered = (yRatio - 0.5) * 2.0
        return -centered * 0.24
    }

    private func startAnimation(to target: CGFloat, duration: CFTimeInterval) {
        stopDisplayLink()
        startProgress = progress
        targetProgress = target
        startTiltAngle = tiltAngle
        animationStartTime = CACurrentMediaTime()
        animationDuration = max(duration * max(abs(target - startProgress), 0.25), 0.12)
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
        // cubic ease-out：松手后快速收拢卷角
        let eased = 1.0 - pow(1.0 - rawT, 3.0)
        progress = startProgress + (targetProgress - startProgress) * CGFloat(eased)
        tiltAngle = startTiltAngle * CGFloat(1.0 - eased)
        metalView?.draw()

        if rawT >= 1.0 {
            stopDisplayLink()
            let completed = curlFromRight ? (targetProgress > 0.5) : (targetProgress < 0.5)
            let forward = activeForward
            if completed, let under = activeUnderImage {
                restingImageView.image = under
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
        let theta = Float(tiltAngle)
        let axisX = cos(theta)
        let axisY = sin(theta)

        // 计算四角在法向量上的投影范围，确定卷轴起止截距。
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(aspect, 0), SIMD2<Float>(0, 1), SIMD2<Float>(aspect, 1)]
        let projections = corners.map { $0.x * axisX + $0.y * axisY }
        let pMin = projections.min() ?? 0
        let pMax = projections.max() ?? aspect

        let baseRadius: Float = 0.13
        let p = Float(progress)
        // 起点/终点附近平滑收缩卷曲半径，使贴合与收尾干脆无突变。
        let edgeRamp = min(min(p / 0.12, (1.0 - p) / 0.12), 1.0)
        let radius = max(baseRadius * (0.35 + 0.65 * max(edgeRamp, 0)), 0.01)

        let dStart = pMax + 0.015
        let dEnd = pMin - (Float.pi * radius) * 0.5 - 0.025
        let axisOffset = dStart + (dEnd - dStart) * p

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
            backOpacity: darkSurface ? 0.08 : 0.14,
            backColor: SIMD4<Float>(Float(r), Float(g), Float(b), Float(a)),
            isUnderLayer: 1.0
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
    };

    struct CurlVertexIn {
        float2 uv [[attribute(0)]];
    };

    struct CurlVertexOut {
        float4 position [[position]];
        float2 uv;
        float angle;
        float signedDist;
        float facing;
    };

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
            out.angle = 0.0;
            out.signedDist = dot(float2(in.uv.x * u.aspect, in.uv.y), float2(u.axisX, u.axisY)) - u.axisOffset;
            out.facing = 1.0;
            return out;
        }

        float2 p = float2(in.uv.x * u.aspect, in.uv.y);
        float2 n = float2(u.axisX, u.axisY);
        float s = dot(p, n) - u.axisOffset;
        float r = max(u.radius, 0.0005);
        float piR = M_PI_F * r;

        float2 finalP = p;
        float z = 0.0;
        float angle = 0.0;
        float facing = 1.0;

        if (s <= 0.0) {
            finalP = p;
            z = 0.0;
            angle = 0.0;
            facing = 1.0;
        } else if (s < piR) {
            float alpha = s / r;
            float delta = r * sin(alpha) - s;
            finalP = p + n * delta;
            z = r * (1.0 - cos(alpha));
            angle = alpha;
            facing = (alpha < M_PI_2_F) ? 1.0 : -1.0;
        } else {
            float delta = -2.0 * s + piR;
            finalP = p + n * delta;
            z = 2.0 * r;
            angle = M_PI_F;
            facing = -1.0;
        }

        float ndcX = (finalP.x / u.aspect) * 2.0 - 1.0;
        float ndcY = 1.0 - finalP.y * 2.0;
        float maxZ = max(2.0 * r, 0.001);
        float depth = clamp(0.8 - (z / maxZ) * 0.7, 0.05, 0.85);

        out.position = float4(ndcX, ndcY, depth, 1.0);
        out.angle = angle;
        out.signedDist = s;
        out.facing = facing;
        return out;
    }

    fragment float4 pageCurlFragment(
        CurlVertexOut in [[stage_in]],
        constant CurlUniforms &u [[buffer(1)]],
        texture2d<float> frontTex [[texture(0)]],
        texture2d<float> underTex [[texture(1)]]
    ) {
        constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

        if (u.isUnderLayer > 0.5) {
            float4 base = underTex.sample(texSampler, in.uv);
            float shadowFade = 1.0 - smoothstep(0.78, 1.0, u.progress);
            float shadowWidth = max(u.radius * 2.2, 0.06);
            float d = in.signedDist;
            float shadow = 0.0;
            if (d >= -0.015 && d < shadowWidth) {
                float t = clamp((d + 0.015) / (shadowWidth + 0.015), 0.0, 1.0);
                shadow = (1.0 - smoothstep(0.0, 1.0, t)) * (u.isDark > 0.5 ? 0.55 : 0.28);
            }
            base.rgb *= (1.0 - shadow * shadowFade);
            return base;
        }

        float4 frontSample = frontTex.sample(texSampler, in.uv);

        if (in.facing > 0.0) {
            float bendShade = 1.0;
            if (in.angle > 0.0) {
                float sinA = sin(in.angle);
                bendShade = 1.0 - (u.isDark > 0.5 ? 0.14 : 0.10) * sinA;
            }
            return float4(frontSample.rgb * bendShade, frontSample.a);
        } else {
            float3 backBase = mix(u.backColor.rgb, frontSample.rgb, u.backOpacity);
            float sinA = sin(clamp(in.angle, 0.0, M_PI_F));

            if (u.isDark > 0.5) {
                // 深色模式：关闭白色镜面高光，仅在折痕弯曲处保留极柔和的深灰立体轮廓
                float3 darkRim = float3(0.045) * pow(sinA, 2.0);
                float darkFoldShadow = 1.0 - 0.14 * (1.0 - sinA);
                return float4(clamp(backBase * darkFoldShadow + darkRim, 0.0, 1.0), 1.0);
            } else {
                float lightSheen = 0.07 * pow(sinA, 1.5);
                float foldShadow = 1.0 - 0.08 * (1.0 - sinA);
                float3 lit = clamp(backBase * foldShadow + float3(lightSheen), 0.0, 1.0);
                return float4(lit, 1.0);
            }
        }
    }
    """
}
