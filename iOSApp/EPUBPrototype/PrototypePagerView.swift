import SwiftUI
import UIKit

// MARK: - 平移翻页视图
//
// 结构：viewport 内一条 strip，从左到右依次放 [上一页 | 当前页 | 下一页]，
// 静止时 strip.x = -W（当前页正对视口）。拖动只改变 strip.x，两张位图一起移动、
// 左右相接。松手吸附动画也只移动 strip；动画结束后 SwiftUI 提交新的当前页，
// 用同一组 PageID 的缓存位图替换内容并把 strip 归零。
// 目标页位图在拖动开始前就已就位；落页即预览，无重排。

struct PrototypePagerView: UIViewRepresentable {
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
    var onAnimatingChange: (Bool) -> Void = { _ in }

    /// 三页位图由宿主从同一份排版缓存派生；每次 SwiftUI 更新都会重放。
    var images: PageImages

    func makeUIView(context: Context) -> PrototypePagerUIView {
        let view = PrototypePagerUIView()
        view.canTurnProvider = canTurn
        view.commitHandler = onCommit
        view.animatingChangeHandler = onAnimatingChange
        view.apply(images: images)
        return view
    }

    func updateUIView(_ view: PrototypePagerUIView, context: Context) {
        view.canTurnProvider = canTurn
        view.commitHandler = onCommit
        view.animatingChangeHandler = onAnimatingChange
        view.apply(images: images)
    }
}

final class PrototypePagerUIView: UIView {
    var canTurnProvider: ((Bool) -> Bool)?
    var commitHandler: ((Bool) -> Void)?
    var animatingChangeHandler: ((Bool) -> Void)?

    private let strip = UIView()
    private let previousImageView = UIImageView()
    private let currentImageView = UIImageView()
    private let nextImageView = UIImageView()

    private var pageSize: CGSize = .zero
    private var images: PrototypePagerView.PageImages = .init(previous: nil, current: nil, next: nil)
    private var isAnimating = false
    private var panBaseX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear

        strip.frame = bounds
        strip.autoresizingMask = []
        addSubview(strip)

        for imageView in [previousImageView, currentImageView, nextImageView] {
            imageView.contentMode = .topLeft
            imageView.clipsToBounds = true
            strip.addSubview(imageView)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: 内容更新

    func apply(images: PrototypePagerView.PageImages) {
        self.images = images
        pageSize = images.size
        layoutStripContent()
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
        // 当前页始终位于中间槽位。
        strip.frame = CGRect(x: -width, y: 0, width: width * 3, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isDragging {
            layoutStripContent()
        }
    }

    private var isDragging: Bool {
        (gestureRecognizers?.first(where: { $0 is UIPanGestureRecognizer })?.state == .began
            || gestureRecognizers?.first(where: { $0 is UIPanGestureRecognizer })?.state == .changed) || isAnimating
    }

    // MARK: 手势

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = max(bounds.width, pageSize.width)
        guard width > 0 else { return }

        switch gesture.state {
        case .began:
            guard !isAnimating else {
                gesture.state = .cancelled
                return
            }
            panBaseX = -width

        case .changed:
            guard !isAnimating else { return }
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
            guard !isAnimating else { return }
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
                return
            }
            completeTurn(forward: direction == true)

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !isAnimating else { return }
        let location = gesture.location(in: self)
        let width = max(bounds.width, pageSize.width)
        let forward = location.x > width / 2
        guard (canTurnProvider?(forward) ?? false),
              (forward ? images.next : images.previous) != nil else { return }
        completeTurn(forward: forward)
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
        }
    }

    /// 吸附到目标页：动画只移动 strip，结束后回调宿主提交新页（宿主用同一 PageID 的
    /// 缓存位图刷新，strip 归零后视觉不变）。
    private func completeTurn(forward: Bool) {
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
        }
    }
}
