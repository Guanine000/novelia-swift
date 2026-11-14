import SwiftUI
import UIKit

/// 页面声明操作，UIKit 仅处理硬件按键；不保存导航、阅读或跨窗口状态。
struct PageKeyAction {
    let input: String
    var modifiers: UIKeyModifierFlags = []
    let title: String
    let perform: (UIView) -> Void

    static func command(_ input: String, _ title: String, action: @escaping () -> Void) -> Self {
        .init(input: input, modifiers: .command, title: title, perform: { _ in action() })
    }
    static func close(_ action: @escaping () -> Void) -> [Self] {
        [.init(input: UIKeyCommand.inputEscape, title: "关闭或返回", perform: { _ in action() }),
         .command("w", "关闭或返回", action: action)]
    }
    static func pages(previous: @escaping () -> Void, next: @escaping () -> Void) -> [Self] {
        [.init(input: UIKeyCommand.inputLeftArrow, title: "上一页", perform: { _ in previous() }),
         .init(input: UIKeyCommand.inputRightArrow, title: "下一页", perform: { _ in next() }),
         .init(input: " ", title: "下一页", perform: { _ in next() }),
         .init(input: " ", modifiers: .shift, title: "上一页", perform: { _ in previous() })]
    }
    /// 滚动阅读使用真实 UIScrollView 的视口高度，不按段落长度猜测翻屏距离。
    static func scrollPages(onManualScroll: @escaping () -> Void) -> [Self] {
        [(UIKeyCommand.inputDownArrow, false, true), (UIKeyCommand.inputUpArrow, false, false),
         (" ", false, true), (" ", true, false)].map { input, shift, forward in
            Self(input: input, modifiers: shift ? .shift : [], title: forward ? "向下阅读" : "向上阅读") { anchor in
                guard let window = anchor.window else { return }
                let center = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: window)
                let scroll = window.keyboardDescendants.compactMap { $0 as? UIScrollView }
                    .filter { !$0.isHidden && $0.alpha > 0 && $0.isScrollEnabled
                        && $0.convert($0.bounds, to: window).contains(center)
                        && $0.contentSize.height > $0.bounds.height }
                    .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
                guard let scroll else { return }
                onManualScroll()
                let low = -scroll.adjustedContentInset.top
                let high = max(low, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let target = min(high, max(low, scroll.contentOffset.y + (forward ? 1 : -1) * scroll.bounds.height * 0.85))
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: true)
            }
        }
    }
}

extension View {
    func pageKeyboardActions(enabled: Bool = true, _ actions: [PageKeyAction]) -> some View {
        modifier(PageKeyboardScope(enabled: enabled, actions: actions))
    }
    func keyboardClose(_ action: @escaping () -> Void) -> some View {
        pageKeyboardActions(PageKeyAction.close(action))
    }
}

private extension UIView {
    var keyboardDescendants: [UIView] { [self] + subviews.flatMap(\.keyboardDescendants) }
    var keyboardVisible: Bool {
        var node: UIView? = self
        while let view = node {
            if view.isHidden || view.alpha < 0.01 { return false }
            node = view.superview
        }
        guard let window else { return false }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top.map { isDescendant(of: $0.view) } ?? false
    }
}

private struct KeyboardPageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var keyboardPageActive: Bool {
        get { self[KeyboardPageActiveKey.self] }
        set { self[KeyboardPageActiveKey.self] = newValue }
    }
}

/// 每个页面持有稳定命令上下文；只把引用发布给 scene，避免闭包数组引起焦点发布反馈。
private struct PageKeyboardScope: ViewModifier {
    @Environment(\.keyboardPageActive) private var pageActive
    @StateObject private var context = PageKeyboardContext()
    @State private var appeared = false
    @State private var inputRevision = 0
    let enabled: Bool
    let actions: [PageKeyAction]
    private var active: Bool { enabled && pageActive && appeared && UIDevice.current.userInterfaceIdiom == .pad }
    func body(content: Content) -> some View {
        let _ = inputRevision
        Group {
            if #available(iOS 16, *) {
                content.background(KeyboardViewportAnchor(context: context, actions: actions, enabled: active))
                    .focusedSceneValue(\.pageKeyboardContext, active ? context : nil)
            } else {
                content.background(KeyboardViewportAnchor(context: context, actions: actions, enabled: active))
                    .focusedValue(\.pageKeyboardContext, context)
            }
        }
#if DEBUG
        .overlay(alignment: .bottomLeading) {
            if Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation" {
                KeyboardScopeValidation(context: context)
            }
        }
        .overlay(alignment: .bottom) {
            if Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation",
               ProcessInfo.processInfo.arguments.contains("-architectureKeyboardUIHooks"), active {
                KeyboardActionValidationBar(context: context)
            }
        }
#endif
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in refreshInput() }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in refreshInput() }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in refreshInput() }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { _ in refreshInput() }
    }
    private func refreshInput() { DispatchQueue.main.async { inputRevision += 1 } }
}
private struct KeyboardViewportAnchor: UIViewRepresentable {
    let context: PageKeyboardContext
    let actions: [PageKeyAction]
    let enabled: Bool
    func makeUIView(context: Context) -> UIView {
#if DEBUG
        if Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation" {
            self.context.anchor.isAccessibilityElement = true
            self.context.anchor.accessibilityIdentifier = "keyboard-input-target"
            self.context.anchor.accessibilityLabel = "键盘导航"
        }
#endif
        return self.context.anchor
    }
    func updateUIView(_ uiView: UIView, context: Context) { self.context.update(actions: actions, enabled: enabled) }
}

/// 在弹层自身声明关闭，避免背后的阅读页响应 Escape 而退出整本书。
private struct KeyboardDismissible: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View { content.keyboardClose { dismiss() } }
}
extension View {
    func keyboardDismissible() -> some View { modifier(KeyboardDismissible()) }
}

/// 鼠标悬停时提供系统右键菜单；触摸长按仍交给书库的连续拖选，不添加菜单预览。
private struct PointerBookMenu<MenuItems: View>: ViewModifier {
    @State private var hovering = false
    let items: () -> MenuItems
    func body(content: Content) -> some View {
        content.onHover { hovering = $0 }
            .contextMenu { if hovering { items() } }
    }
}
extension View {
    func pointerBookMenu<Items: View>(@ViewBuilder items: @escaping () -> Items) -> some View {
        modifier(PointerBookMenu(items: items))
    }
}


private struct PageKeyDescriptor: Identifiable, Equatable {
    let input: String
    let modifiers: UIKeyModifierFlags
    let title: String
    var id: String { input + ":" + String(modifiers.rawValue) }
}
/// UIView、操作闭包与可用状态仅属于此页；菜单只观察可比较的说明，不观察每次重建的闭包。
private final class PageKeyboardContext: ObservableObject {
    let anchor = KeyboardCommandReceiver()
    @Published private(set) var descriptors: [PageKeyDescriptor] = []
#if DEBUG
    @Published private(set) var lastAction = "none"
    @Published fileprivate var delivery = "none"
#endif
    private var actions: [PageKeyAction] = []
    fileprivate var enabled = false
    func update(actions: [PageKeyAction], enabled: Bool) {
        self.actions = actions; self.enabled = enabled
        anchor.context = self
        if !enabled { anchor.resignFirstResponder() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let next = (self.enabled ? self.actions : []).filter { !self.hasTextFocus || !$0.requiresIdleInput }.map {
                PageKeyDescriptor(input: $0.input, modifiers: $0.modifiers, title: $0.title)
            }
            let changed = self.descriptors != next
            if changed { self.descriptors = next }
            self.anchor.refresh(reload: changed)
        }
    }
    fileprivate var hasTextFocus: Bool {
        guard let responder = anchor.window?.keyboardDescendants.first(where: { $0.isFirstResponder }) else { return false }
        if responder is UITextField { return true }
        if let text = responder as? UITextView, text.isEditable { return true }
        if let input = responder as? UITextInput, let range = input.selectedTextRange, !range.isEmpty { return true }
        return false
    }
    func perform(_ id: String) {
#if DEBUG
        lastAction = id
#endif
        guard enabled, anchor.keyboardVisible,
              let action = actions.first(where: { $0.input + ":" + String($0.modifiers.rawValue) == id }),
              !action.requiresIdleInput || !hasTextFocus else { return }
        action.perform(anchor)
    }
}
/// 为非文本页面建立硬件键盘输入目标；空 inputView 不展示软键盘。
/// UIKit 编辑框、选区及完整键盘控制中的控件保留焦点，命令目标始终限制在本窗口当前页面。
private final class KeyboardCommandReceiver: UIView, UIKeyInput {
    weak var context: PageKeyboardContext?
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? { emptyInputView }
    override var canBecomeFirstResponder: Bool { context?.enabled == true && keyboardVisible }
    var hasText: Bool { false }
    func insertText(_ text: String) {
#if DEBUG
        context?.delivery = "text-input"
#endif
    }
    func deleteBackward() { }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refresh() }
        else { resignFirstResponder() }
    }
    func refresh(reload: Bool = false) {
        guard let context, context.enabled else { resignFirstResponder(); return }
        guard keyboardVisible, !context.hasTextFocus, let window else { return }
        let current = window.keyboardDescendants.first { $0.isFirstResponder }
        if let current, current !== self {
            if current is UIControl { return }
            if let receiver = current as? KeyboardCommandReceiver,
               receiver.context?.enabled == true && receiver.keyboardVisible { return }
        }
        if reload && isFirstResponder { resignFirstResponder() }
        becomeFirstResponder()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isFirstResponder, let context else { super.pressesBegan(presses, with: event); return }
        var remaining = presses
        for press in presses {
            guard let key = press.key else { continue }
            let flags = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
#if DEBUG
            context.delivery = "press=\(key.keyCode.rawValue) flags=\(flags.rawValue)"
#endif
            let id = key.charactersIgnoringModifiers + ":" + String(flags.rawValue)
            if context.descriptors.contains(where: { $0.id == id }) {
                context.perform(id); remaining.remove(press)
            }
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard let context, context.enabled, keyboardVisible else { return [] }
        return context.descriptors.map { descriptor in
            let command = UIKeyCommand(input: descriptor.input, modifierFlags: descriptor.modifiers, action: #selector(handleKey(_:)))
            command.discoverabilityTitle = descriptor.title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleKey(_:)) { return context?.enabled == true && keyboardVisible }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc private func handleKey(_ command: UIKeyCommand) {
        guard isFirstResponder else { return }
        context?.perform((command.input ?? "") + ":" + String(command.modifierFlags.rawValue))
    }
}

private struct PageKeyboardContextKey: FocusedValueKey { typealias Value = PageKeyboardContext }
private extension FocusedValues {
    var pageKeyboardContext: PageKeyboardContext? {
        get { self[PageKeyboardContextKey.self] }
        set { self[PageKeyboardContextKey.self] = newValue }
    }
}
struct PageKeyboardCommands: Commands {
    @FocusedValue(\.pageKeyboardContext) private var context
    var body: some Commands {
        CommandMenu("浏览与阅读") {
            if let context { PageKeyboardMenuItems(context: context) }
        }
    }
}
private struct PageKeyboardMenuItems: View {
    @ObservedObject var context: PageKeyboardContext
    var body: some View {
        ForEach(context.descriptors) { command in
            Button(command.title) { context.perform(command.id) }
                .keyboardShortcut(command.equivalent, modifiers: command.eventModifiers)
        }
    }
}
private extension PageKeyDescriptor {
    var equivalent: KeyEquivalent {
        switch input {
        case UIKeyCommand.inputUpArrow: return .upArrow
        case UIKeyCommand.inputDownArrow: return .downArrow
        case UIKeyCommand.inputLeftArrow: return .leftArrow
        case UIKeyCommand.inputRightArrow: return .rightArrow
        case UIKeyCommand.inputEscape: return .escape
        case "\r": return .return
        default: return KeyEquivalent(input.first ?? " ")
        }
    }
    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if modifiers.contains(.command) { value.insert(.command) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.alternate) { value.insert(.option) }
        if modifiers.contains(.control) { value.insert(.control) }
        return value
    }
}

private extension PageKeyAction {
    var requiresIdleInput: Bool { !modifiers.contains(.command) || input == "\r" }
}

#if DEBUG
/// 只验证同一命令回调的页面路由，不替代硬件按键投递测试。
private struct KeyboardActionValidationBar: View {
    @ObservedObject var context: PageKeyboardContext
    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(context.descriptors) { command in
                    Button(command.title) { context.perform(command.id) }
                        .accessibilityIdentifier("keyboard-action-" + command.id)
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        }
        .frame(height: 44)
        .background(.regularMaterial)
        .accessibilityIdentifier("keyboard-validation-actions")
    }
}
private struct KeyboardScopeValidation: View {
    @ObservedObject var context: PageKeyboardContext
    var body: some View {
        Text("actions=\(context.descriptors.count) window=\(context.anchor.window != nil) visible=\(context.anchor.keyboardVisible) first=\(context.anchor.isFirstResponder) last=\(context.lastAction) delivery=\(context.delivery)")
            .accessibilityIdentifier("keyboard-validation-scope").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
    }
}
struct KeyboardValidationIndicator: View {
    @FocusedValue(\.pageKeyboardContext) private var context
    var body: some View {
        Group {
            if let context { KeyboardFocusedValidation(context: context) }
            else { Text("focused=0") }
        }
        .accessibilityIdentifier("keyboard-validation-focused").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
    }
}
private struct KeyboardFocusedValidation: View {
    @ObservedObject var context: PageKeyboardContext
    var body: some View { Text("focused=\(context.descriptors.count)") }
}
#endif
