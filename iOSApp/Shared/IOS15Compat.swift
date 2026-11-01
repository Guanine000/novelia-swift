import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// iOS 15 兼容层。NoveliaLegacy（部署目标 iOS 15）与主目标 Novelia（iOS 17）编译同一份界面源码。
// iOS 16/17 的界面 API 集中在这里分支：新系统走原来的系统控件，旧系统走降级实现。
// 主目标运行在 iOS 17 及以上时只走新系统分支。阅读进度、书库和同步不经过本文件。

extension ToolbarItemPlacement {
    /// 导航栏前缘。iOS 17 使用 `topBarLeading`，更早系统使用仍可用的 `navigationBarLeading`。
    static var compatTopBarLeading: ToolbarItemPlacement {
        if #available(iOS 17, *) { .topBarLeading } else { .navigationBarLeading }
    }

    /// 导航栏后缘。与 `compatTopBarLeading` 同一套分支。
    static var compatTopBarTrailing: ToolbarItemPlacement {
        if #available(iOS 17, *) { .topBarTrailing } else { .navigationBarTrailing }
    }
}

extension View {
    /// iOS 17 的双参数 `onChange`。`initial` 为真时，出现时立刻以相同的旧值和新值调用一次。
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, initial: Bool = false, perform action: @escaping (V, V) -> Void) -> some View {
        if #available(iOS 17, *) {
            self.onChange(of: value, initial: initial, action)
        } else {
            self.modifier(LegacyValueChange(value: value, initial: initial, action: action))
        }
    }

    @ViewBuilder
    func compatNavigationDestination<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        if #available(iOS 16, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self.background(
                NavigationLink(destination: destination(), isActive: isPresented) { EmptyView() }
                    .hidden()
            )
        }
    }

    @ViewBuilder
    func compatNavigationDestination<Item: Hashable, Destination: View>(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        if #available(iOS 17, *) {
            self.navigationDestination(item: item, destination: destination)
        } else if #available(iOS 16, *) {
            // `navigationDestination(item:)` 从 iOS 17 起才有。iOS 16 用布尔形式，关闭时同样清空条目。
            self.navigationDestination(isPresented: isPresented) {
                if let value = item.wrappedValue {
                    destination(value)
                }
            }
        } else {
            self.background(
                NavigationLink(
                    destination: Group {
                        if let value = item.wrappedValue { destination(value) }
                    },
                    isActive: isPresented
                ) { EmptyView() }
                .hidden()
            )
        }
    }

    /// iOS 16 起使用系统 detent。iOS 15 只有 medium / large，自定义高度退回 medium。
    @ViewBuilder
    func compatPresentationDetents(_ detents: CompatDetent...) -> some View {
        if #available(iOS 16, *) {
            self.presentationDetents(Set(detents.map { detent in
                switch detent {
                case .medium: return PresentationDetent.medium
                case .large: return PresentationDetent.large
                case .height(let value): return PresentationDetent.height(value)
                }
            }))
        } else {
            self.background(LegacySheetConfigurator(detents: detents, showsGrabber: nil))
        }
    }

    @ViewBuilder
    func compatPresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self.background(LegacySheetConfigurator(detents: nil, showsGrabber: true))
        }
    }

    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(style)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self.background(ScrollViewAdjuster(clearListBackground: true))
        }
    }

    @ViewBuilder
    func compatScrollDismissesKeyboardInteractively() -> some View {
        if #available(iOS 16, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self.background(ScrollViewAdjuster(keyboardDismissInteractive: true))
        }
    }

    @ViewBuilder
    func compatScrollIndicatorsHidden() -> some View {
        if #available(iOS 16, *) {
            self.scrollIndicators(.hidden)
        } else {
            self.background(ScrollViewAdjuster(hideIndicators: true))
        }
    }

    @ViewBuilder
    func compatToolbar(_ visibility: CompatToolbarVisibility, for bar: CompatBar) -> some View {
        if #available(iOS 16, *) {
            switch (visibility, bar) {
            case (.hidden, .navigationBar): self.toolbar(.hidden, for: .navigationBar)
            case (.visible, .navigationBar): self.toolbar(.visible, for: .navigationBar)
            case (.hidden, .tabBar): self.toolbar(.hidden, for: .tabBar)
            case (.visible, .tabBar): self.toolbar(.visible, for: .tabBar)
            }
        } else {
            switch (visibility, bar) {
            case (.hidden, .navigationBar): self.navigationBarHidden(true)
            case (.visible, .navigationBar): self.navigationBarHidden(false)
            case (.hidden, .tabBar): self.background(LegacyTabBarVisibility(hidden: true))
            case (.visible, .tabBar): self.background(LegacyTabBarVisibility(hidden: false))
            }
        }
    }

    /// `autocorrectionDisabled` 从 iOS 16 起可用。更早系统使用原来的 `disableAutocorrection`。
    @ViewBuilder
    func compatAutocorrectionDisabled() -> some View {
        if #available(iOS 16, *) {
            self.autocorrectionDisabled()
        } else {
            self.disableAutocorrection(true)
        }
    }

    /// 数字键盘上方的完成按钮。iOS 16 及以上只在需要时加入工具栏项；
    /// iOS 15 的工具栏不能写不带 else 的 if，因此始终挂上键盘栏，按钮仍按条件显示，避免重建输入框。
    func compatKeyboardJumpToolbar(isPresented: Bool, action: @escaping () -> Void) -> some View {
        if #available(iOS 16, *) {
            return AnyView(self.toolbar {
                if isPresented {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("跳转", action: action)
                    }
                }
            })
        } else {
            return AnyView(self.toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if isPresented {
                        Spacer()
                        Button("跳转", action: action)
                    }
                }
            })
        }
    }

    /// `View.fontWeight` 从 iOS 16 起可用。按钮在更早系统上改用同等字重的正文字体。
    @ViewBuilder
    func compatFontWeight(_ weight: Font.Weight) -> some View {
        if #available(iOS 16, *) {
            self.fontWeight(weight)
        } else {
            self.font(.body.weight(weight))
        }
    }
}

extension Text {
    /// `Text.tracking` 从 iOS 16 起可用。更早系统用字距近似，只影响英文大写装饰标题。
    func compatTracking(_ tracking: CGFloat) -> Text {
        if #available(iOS 16, *) {
            self.tracking(tracking)
        } else {
            self.kerning(tracking)
        }
    }
}

enum CompatDetent {
    case medium
    case large
    case height(CGFloat)
}

enum CompatBar {
    case navigationBar
    case tabBar
}

enum CompatToolbarVisibility {
    case hidden
    case visible
}

struct CompatNavigationStack<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

struct CompatLabeledContent: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    // 显式返回类型擦除后的视图，避免优化编译将旧系统分支推导为 iOS 26 的 TupleContent。
    var body: some View {
        if #available(iOS 16, *) {
            return AnyView(LabeledContent(title, value: value))
        } else {
            return AnyView(HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            })
        }
    }
}

struct CompatUnavailable<LabelContent: View, Description: View, Actions: View>: View {
    private let label: LabelContent
    private let description: Description
    private let actions: Actions

    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description, @ViewBuilder actions: () -> Actions) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        if #available(iOS 17, *) {
            return AnyView(ContentUnavailableView(label: { label }, description: { description }, actions: { actions }))
        } else {
            return AnyView(VStack(spacing: 12) {
                label
                description
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity))
        }
    }
}

extension CompatUnavailable where Actions == EmptyView {
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension CompatUnavailable where LabelContent == Label<Text, Image>, Description == EmptyView, Actions == EmptyView {
    init(_ title: String, systemImage: String) {
        self.init { Label(title, systemImage: systemImage) } description: { EmptyView() }
    }
}

extension CompatUnavailable where LabelContent == Label<Text, Image>, Description == Text, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text) {
        self.init { Label(title, systemImage: systemImage) } description: { description }
    }
}

struct CompatSearchUnavailable: View {
    let text: String

    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView.search(text: text)
        } else {
            CompatUnavailable {
                Label(text.isEmpty ? "无结果" : "找不到“\(text)”", systemImage: "magnifyingglass")
            } description: {
                Text("请检查拼写或尝试新搜索。")
            }
        }
    }
}

struct CompatShareLink<Label: View>: View {
    let item: URL
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(iOS 16, *) {
            ShareLink(item: item, label: label)
        } else {
            Button {
                ActivityPresenter.present(items: [item])
            } label: {
                label()
            }
        }
    }
}

struct CompatVerticalTextField: View {
    let prompt: String
    @Binding var text: String
    var limit: ClosedRange<Int>

    var body: some View {
        if #available(iOS 16, *) {
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(limit)
        } else {
            TextEditor(text: $text)
                .frame(minHeight: CGFloat(limit.lowerBound) * 22, maxHeight: CGFloat(limit.upperBound) * 22)
        }
    }
}

struct CompatPhotosPickerButton<Label: View>: View {
    var isDisabled = false
    let onData: (Data) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(iOS 16, *) {
            ModernPhotoPickerButton(isDisabled: isDisabled, onData: onData, label: label)
        } else {
            LegacyPhotoPickerButton(isDisabled: isDisabled, onData: onData, label: label)
        }
    }
}

@available(iOS 16, *)
private struct ModernPhotoPickerButton<Label: View>: View {
    var isDisabled: Bool
    let onData: (Data) -> Void
    @ViewBuilder var label: () -> Label
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, label: label)
            .disabled(isDisabled)
            .onValueChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task {
                    defer { item = nil }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        onData(data)
                    }
                }
            }
    }
}

private struct LegacyPhotoPickerButton<Label: View>: View {
    var isDisabled: Bool
    let onData: (Data) -> Void
    @ViewBuilder var label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented = true }, label: label)
            .disabled(isDisabled)
            .background(LegacyPhotoPickerPresenter(isPresented: $isPresented, onData: onData))
    }
}

private struct LegacyValueChange<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var previous: V?
    @State private var didStart = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didStart else { return }
                didStart = true
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { newValue in
                let oldValue = previous ?? newValue
                previous = newValue
                action(oldValue, newValue)
            }
    }
}

private struct LegacySheetConfigurator: UIViewControllerRepresentable {
    var detents: [CompatDetent]?
    var showsGrabber: Bool?

    func makeUIViewController(context: Context) -> Controller {
        Controller(detents: detents, showsGrabber: showsGrabber)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.detents = detents
        controller.showsGrabber = showsGrabber
        controller.apply()
    }

    final class Controller: UIViewController {
        var detents: [CompatDetent]?
        var showsGrabber: Bool?

        init(detents: [CompatDetent]?, showsGrabber: Bool?) {
            self.detents = detents
            self.showsGrabber = showsGrabber
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
            DispatchQueue.main.async { self.apply() }
        }

        /// iOS 15 的 sheet 只有 medium 与 large。调用方要求固定高度时使用 medium。
        func apply() {
            guard let sheet = enclosingSheet else { return }
            if let detents {
                var mapped: [UISheetPresentationController.Detent] = []
                for detent in detents {
                    switch detent {
                    case .medium: mapped.append(.medium())
                    case .large: mapped.append(.large())
                    case .height: break
                    }
                }
                // 固定高度在 iOS 15 不存在，只请求高度时使用 medium。
                if mapped.isEmpty { mapped = [.medium()] }
                sheet.detents = mapped
            }
            if let showsGrabber { sheet.prefersGrabberVisible = showsGrabber }
        }

        private var enclosingSheet: UISheetPresentationController? {
            var current: UIViewController? = self
            while let controller = current {
                if let sheet = controller.sheetPresentationController { return sheet }
                current = controller.parent
            }
            return nil
        }
    }
}

private struct LegacyTabBarVisibility: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(hidden: hidden) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hidden = hidden
        controller.apply()
    }

    final class Controller: UIViewController {
        var hidden: Bool
        init(hidden: Bool) {
            self.hidden = hidden
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if hidden { tabBarController?.tabBar.isHidden = false }
        }

        func apply() { tabBarController?.tabBar.isHidden = hidden }
    }
}

private struct ScrollViewAdjuster: UIViewRepresentable {
    var clearListBackground = false
    var keyboardDismissInteractive = false
    var hideIndicators = false

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView
            var cleared = false
            var dismissed = false
            var hidden = false
            while let view = current {
                if let scroll = view as? UIScrollView {
                    if clearListBackground, !cleared, let table = scroll as? UITableView {
                        table.backgroundColor = .clear
                        let background = UIView()
                        background.backgroundColor = .clear
                        table.backgroundView = background
                        cleared = true
                    }
                    if keyboardDismissInteractive, !dismissed {
                        scroll.keyboardDismissMode = .interactive
                        dismissed = true
                    }
                    if hideIndicators, !hidden {
                        scroll.showsVerticalScrollIndicator = false
                        scroll.showsHorizontalScrollIndicator = false
                        hidden = true
                    }
                }
                if (cleared || !clearListBackground), (dismissed || !keyboardDismissInteractive), (hidden || !hideIndicators) {
                    break
                }
                current = view.superview
            }
        }
    }
}

private struct LegacyPhotoPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onData: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, controller.presentedViewController == nil else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        presenter(from: controller).present(picker, animated: true)
    }

    private func presenter(from controller: UIViewController) -> UIViewController {
        var current = controller
        while let parent = current.parent { current = parent }
        return current
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: LegacyPhotoPickerPresenter
        init(parent: LegacyPhotoPickerPresenter) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let type = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else { return }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { self.parent.onData(data) }
            }
        }
    }
}

private enum ActivityPresenter {
    static func present(items: [Any]) {
        DispatchQueue.main.async {
            guard let controller = topViewController() else { return }
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            controller.present(activity, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
