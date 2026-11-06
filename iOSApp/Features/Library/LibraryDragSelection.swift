import SwiftUI
import UIKit

struct LibraryRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// List继续负责复用和普通滚动；长按识别成功后才接管拖选和边缘滚动。
struct LibraryDragSelectionModifier: ViewModifier {
    let books: [LibraryBook]
    let actions: LibraryBookActions
    @State private var frames: [String: CGRect] = [:]
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(LibraryRowFrames.self) { frames = $0 }
            .background(LibraryDragSelectionBridge(keys: books.map(\.key), frames: frames, actions: actions))
    }
}

private struct LibraryDragSelectionBridge: UIViewRepresentable {
    let keys: [String]
    let frames: [String: CGRect]
    let actions: LibraryBookActions
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.keys = keys; context.coordinator.frames = frames; context.coordinator.actions = actions
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }; coordinator?.attach(from: view)
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var keys: [String] = []
        var frames: [String: CGRect] = [:]
        weak var actions: LibraryBookActions?
        weak var scroll: UIScrollView?
        var selection: LibraryRangeSelection?
        var originallySelecting = false
        var point = CGPoint.zero
        var displayLink: CADisplayLink?
        lazy var press: UILongPressGestureRecognizer = {
            let value = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
            value.minimumPressDuration = 0.45; value.allowableMovement = 12; value.delegate = self
            return value
        }()
        func attach(from view: UIView) {
            guard scroll == nil else { return }
            func find(_ root: UIView) -> UIScrollView? {
                if let value = root as? UIScrollView { return value }
                for child in root.subviews { if let found = find(child) { return found } }
                return nil
            }
            var parent = view.superview
            while let current = parent {
                if let target = find(current) { scroll = target; target.addGestureRecognizer(press); return }
                parent = current.superview
            }
        }
        func detach() { displayLink?.invalidate(); displayLink = nil; scroll?.removeGestureRecognizer(press); selection = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let p = touch.location(in: nil)
            return frames.contains { keys.contains($0.key) && $0.value.contains(p) }
        }
        @objc func drag(_ gesture: UILongPressGestureRecognizer) {
            point = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                guard let key = frames.first(where: { $0.value.contains(point) && keys.contains($0.key) })?.key,
                      let index = keys.firstIndex(of: key), let actions else { return }
                originallySelecting = actions.isSelecting
                selection = LibraryRangeSelection(original: actions.selectedKeys, anchor: index, selects: !actions.selectedKeys.contains(key))
                updateSelection()
                let link = CADisplayLink(target: self, selector: #selector(tick)); link.add(to: .main, forMode: .common); displayLink = link
            case .changed: updateSelection()
            case .ended: updateSelection(); selection = nil; displayLink?.invalidate(); displayLink = nil
            case .cancelled, .failed:
                if let selection { actions?.applyDragSelection(selection.original, selecting: originallySelecting) }
                selection = nil; displayLink?.invalidate(); displayLink = nil
            default: break
            }
        }
        private func updateSelection() {
            guard let selection, let nearest = frames.filter({ keys.contains($0.key) }).min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }),
                  let index = keys.firstIndex(of: nearest.key) else { return }
            actions?.applyDragSelection(selection.selection(through: index, orderedKeys: keys))
        }
        @objc func tick() {
            guard selection != nil, let scroll, !scroll.isDragging else { return }
            let bounds = scroll.convert(scroll.bounds, to: nil)
            let margin: CGFloat = 60
            let velocity: CGFloat
            if point.y < bounds.minY + margin { velocity = -min(8, (bounds.minY + margin - point.y) / 6) }
            else if point.y > bounds.maxY - margin { velocity = min(8, (point.y - bounds.maxY + margin) / 6) }
            else { return }
            let lower = -scroll.adjustedContentInset.top
            let upper = max(lower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = min(upper, max(lower, scroll.contentOffset.y + velocity))
            if next != scroll.contentOffset.y { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false) }
            updateSelection()
        }
    }
}
