import SwiftUI
import UIKit
import WebKit

struct NoveliaLoginSheet: View {
    @ObservedObject var auth: AccountAuthStore

    var body: some View {
        LoginMethods { back in
            NoveliaWebsiteLoginSheet(auth: auth, onBack: back)
        } password: { openWebsite in
            NoveliaPasswordLoginSheet(auth: auth, onOpenWebsite: openWebsite)
        }
    }
}

struct ForumLoginSheet: View {
    @ObservedObject var auth: ForumAuthStore

    var body: some View {
        LoginMethods { back in
            ForumWebsiteLoginSheet(auth: auth, onBack: back)
        } password: { openWebsite in
            ForumPasswordLoginSheet(auth: auth, onOpenWebsite: openWebsite)
        }
    }
}

private struct LoginMethods<Website: View, Password: View>: View {
    let website: (@escaping () -> Void) -> Website
    let password: (@escaping () -> Void) -> Password
    @State private var showsWebsite = false

    var body: some View {
        if showsWebsite {
            website { showsWebsite = false }
        } else {
            password { showsWebsite = true }
        }
    }
}

private struct NoveliaPasswordLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AccountAuthStore

    let onOpenWebsite: () -> Void

    var body: some View {
        NoveliaNativeLoginForm(
            configuration: auth.configuration.authentication,
            isBusy: auth.isRefreshing,
            errorMessage: auth.errorMessage,
            existingAccountUsername: nil,
            onClearError: { auth.errorMessage = nil },
            onSyncExistingAccount: nil,
            onSubmit: { username, password in
                if await auth.login(username: username, password: password) {
                    dismiss()
                    return true
                }
                return false
            },
            onOpenWebsite: onOpenWebsite,
            onClose: { dismiss() }
        )
    }
}

private struct ForumPasswordLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: ForumAuthStore

    let onOpenWebsite: () -> Void

    var body: some View {
        NoveliaNativeLoginForm(
            configuration: auth.configuration.authentication,
            isBusy: auth.isRefreshing || auth.accountAuth?.isRefreshing == true,
            errorMessage: auth.errorMessage,
            existingAccountUsername: auth.accountAuth?.username,
            onClearError: { auth.errorMessage = nil },
            onSyncExistingAccount: {
                if await auth.establishUnifiedSession() {
                    dismiss()
                    return true
                }
                return false
            },
            onSubmit: { username, password in
                if await auth.login(username: username, password: password) {
                    dismiss()
                    return true
                }
                return false
            },
            onOpenWebsite: onOpenWebsite,
            onClose: { dismiss() }
        )
    }
}

private struct LoginCredentials: Equatable {
    var username = ""
    var password = ""
}

/// 原生账密登录表单；注册与找回密码通过外部浏览器打开已校验的官网链接，避免内置 Turnstile 网页桥接。
private struct NoveliaNativeLoginForm: View {
    @Environment(\.openURL) private var openURL
    let configuration: AuthenticationConfiguration
    let isBusy: Bool
    let errorMessage: String?
    let existingAccountUsername: String?
    let onClearError: () -> Void
    let onSyncExistingAccount: (() async -> Bool)?
    let onSubmit: (String, String) async -> Bool
    let onOpenWebsite: () -> Void
    let onClose: () -> Void

    @State private var credentials = LoginCredentials()
    @State private var dismissKeyboardToken = 0

    private var canSubmit: Bool {
        !isBusy && !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !credentials.password.isEmpty
    }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录 Novelia 账号")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(NoveliaStyle.ink)
                        Text("使用用户名或注册邮箱登录，将同时建立小说与社区会话。")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
                    }

                    if let existingAccountUsername, let onSyncExistingAccount {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("当前已登录账号「\(existingAccountUsername)」，可直接同步社区会话，或在下方重新输入账号登录。")
                                .font(.footnote)
                                .foregroundStyle(NoveliaStyle.muted)
                            Button {
                                Task { _ = await onSyncExistingAccount() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isBusy { ProgressView().controlSize(.small) }
                                    Text(isBusy ? "同步中…" : "使用当前账号同步社区会话")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .tint(NoveliaStyle.brandGreen)
                            .disabled(isBusy)
                        }
                        .padding(14)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
                    }

                    LoginCredentialsCardView(
                        onCredentialsChanged: { credentials = $0 },
                        isEnabled: !isBusy,
                        dismissKeyboardToken: dismissKeyboardToken,
                        onSubmit: { submitIfReady() }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))

                    if let errorMessage, !errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(NoveliaStyle.danger)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(NoveliaStyle.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        submitIfReady()
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            }
                            Text(isBusy ? "登录中…" : "登录")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(!canSubmit)

                    Button("使用官网网页登录", action: onOpenWebsite)
                        .frame(maxWidth: .infinity)
                        .tint(NoveliaStyle.brandGreen)
                        .disabled(isBusy)

                    VStack(spacing: 8) {
                        Text("还没有账号，或忘记密码？")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
                        Button {
                            openURL(configuration.loginURL(app: "n"))
                        } label: {
                            HStack(spacing: 4) {
                                Text("在浏览器中注册 / 找回密码")
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .font(.footnote.weight(.medium))
                        }
                        .tint(NoveliaStyle.brandGreen)
                        .disabled(isBusy)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                        .disabled(isBusy)
                }
            }
        }
        .onAppear { onClearError() }
        .onDisappear { credentials.password = "" }
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        let submitted = credentials
        dismissKeyboardToken &+= 1
        Task {
            if await onSubmit(submitted.username, submitted.password) {
                credentials.password = ""
            }
        }
    }
}

/// 监听所有 UIKit 写入路径（包括系统钥匙串静默设置 .text / insertText / replace）的输入框。
private final class AutoFillAwareTextField: UITextField {
    var onTextMutation: (() -> Void)?

    override var text: String? {
        didSet {
            if text != oldValue {
                onTextMutation?()
            }
        }
    }

    override var attributedText: NSAttributedString? {
        didSet { onTextMutation?() }
    }

    override func insertText(_ text: String) {
        super.insertText(text)
        onTextMutation?()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        super.replace(range, withText: text)
        onTextMutation?()
    }
}

/// 单一 UIKit 凭据容器：用户名与密码框作为直接同级视图共处同一父视图，避免 SwiftUI 包装层与焦点回写打断 iCloud 钥匙串自动填充。
private final class LoginCredentialsContainerView: UIView {
    let usernameField = AutoFillAwareTextField(frame: .zero)
    let passwordField = AutoFillAwareTextField(frame: .zero)
    let visibilityButton = UIButton(type: .system)
    private var isPasswordVisible = false
    private static let fieldVerticalInset: CGFloat = 12
    var onToggleVisibility: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        let mutedColor = UIColor(NoveliaStyle.muted)
        let hairlineColor = UIColor(NoveliaStyle.hairline)

        let userIcon = makeIconView(systemName: "person", tint: mutedColor)
        let lockIcon = makeIconView(systemName: "lock", tint: mutedColor)

        configureField(
            usernameField,
            placeholder: "用户名或邮箱",
            contentType: .username,
            isSecure: false,
            returnKeyType: .next
        )
        configureField(
            passwordField,
            placeholder: "密码",
            contentType: .password,
            isSecure: true,
            returnKeyType: .go
        )

        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.tintColor = mutedColor
        visibilityButton.addTarget(self, action: #selector(handleVisibilityTap), for: .touchUpInside)
        updateVisibilityButtonAppearance()

        let divider = UIView(frame: .zero)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = hairlineColor

        let usernameRow = UIView(frame: .zero)
        usernameRow.translatesAutoresizingMaskIntoConstraints = false
        usernameRow.addSubview(userIcon)

        let passwordRow = UIView(frame: .zero)
        passwordRow.translatesAutoresizingMaskIntoConstraints = false
        passwordRow.addSubview(lockIcon)
        passwordRow.addSubview(visibilityButton)

        addSubview(usernameRow)
        addSubview(divider)
        addSubview(passwordRow)
        addSubview(usernameField)
        addSubview(passwordField)

        NSLayoutConstraint.activate([
            usernameRow.topAnchor.constraint(equalTo: topAnchor),
            usernameRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            usernameRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            usernameRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            userIcon.leadingAnchor.constraint(equalTo: usernameRow.leadingAnchor, constant: 14),
            userIcon.centerYAnchor.constraint(equalTo: usernameRow.centerYAnchor),
            userIcon.widthAnchor.constraint(equalToConstant: 20),

            usernameField.leadingAnchor.constraint(equalTo: userIcon.trailingAnchor, constant: 10),
            usernameField.trailingAnchor.constraint(equalTo: usernameRow.trailingAnchor, constant: -14),
            usernameField.topAnchor.constraint(equalTo: usernameRow.topAnchor, constant: Self.fieldVerticalInset),
            usernameField.bottomAnchor.constraint(equalTo: usernameRow.bottomAnchor, constant: -Self.fieldVerticalInset),

            divider.topAnchor.constraint(equalTo: usernameRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            passwordRow.topAnchor.constraint(equalTo: divider.bottomAnchor),
            passwordRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            passwordRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            passwordRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            passwordRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            lockIcon.leadingAnchor.constraint(equalTo: passwordRow.leadingAnchor, constant: 14),
            lockIcon.centerYAnchor.constraint(equalTo: passwordRow.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 20),

            passwordField.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 10),
            passwordField.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -6),
            passwordField.topAnchor.constraint(equalTo: passwordRow.topAnchor, constant: Self.fieldVerticalInset),
            passwordField.bottomAnchor.constraint(equalTo: passwordRow.bottomAnchor, constant: -Self.fieldVerticalInset),

            visibilityButton.trailingAnchor.constraint(equalTo: passwordRow.trailingAnchor, constant: -10),
            visibilityButton.centerYAnchor.constraint(equalTo: passwordRow.centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalToConstant: 32),
            visibilityButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func makeIconView(systemName: String, tint: UIColor) -> UIImageView {
        let imageView = UIImageView(image: UIImage(systemName: systemName))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = tint
        imageView.contentMode = .scaleAspectFit
        return imageView
    }

    private func configureField(
        _ field: AutoFillAwareTextField,
        placeholder: String,
        contentType: UITextContentType,
        isSecure: Bool,
        returnKeyType: UIReturnKeyType
    ) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = placeholder
        field.textContentType = contentType
        field.isSecureTextEntry = isSecure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.keyboardType = .default
        field.returnKeyType = returnKeyType
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func handleVisibilityTap() {
        isPasswordVisible.toggle()
        onToggleVisibility?()
        updateVisibilityButtonAppearance()
    }

    func applyPasswordVisibility() {
        let shouldBeSecure = !isPasswordVisible
        guard passwordField.isSecureTextEntry != shouldBeSecure else { return }
        let wasFirstResponder = passwordField.isFirstResponder
        let existing = passwordField.text
        passwordField.isSecureTextEntry = shouldBeSecure
        if wasFirstResponder, let existing {
            passwordField.text = nil
            passwordField.insertText(existing)
        }
    }

    private func updateVisibilityButtonAppearance() {
        let symbol = isPasswordVisible ? "eye.slash" : "eye"
        visibilityButton.setImage(UIImage(systemName: symbol), for: .normal)
        visibilityButton.accessibilityLabel = isPasswordVisible ? "隐藏密码" : "显示密码"
    }

    override var intrinsicContentSize: CGSize {
        // SwiftUI 正在测量根容器时不能在同一个视图上再启动 Auto Layout 测量。
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let rowHeight = max(48, ceil(font.lineHeight) + 2 * Self.fieldVerticalInset)
        return CGSize(width: UIView.noIntrinsicMetric, height: 2 * rowHeight + 1)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            invalidateIntrinsicContentSize()
        }
    }
}

private struct LoginCredentialsCardView: UIViewRepresentable {
    let onCredentialsChanged: (LoginCredentials) -> Void
    let isEnabled: Bool
    let dismissKeyboardToken: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> LoginCredentialsContainerView {
        let container = LoginCredentialsContainerView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.container = container

        container.usernameField.delegate = coordinator
        container.passwordField.delegate = coordinator
        container.usernameField.addTarget(coordinator, action: #selector(Coordinator.fieldsDidChange), for: .editingChanged)
        container.passwordField.addTarget(coordinator, action: #selector(Coordinator.fieldsDidChange), for: .editingChanged)
        container.usernameField.onTextMutation = { [weak coordinator] in coordinator?.syncFromFields() }
        container.passwordField.onTextMutation = { [weak coordinator] in coordinator?.syncFromFields() }
        container.onToggleVisibility = { [weak coordinator, weak container] in
            container?.applyPasswordVisibility()
            coordinator?.syncFromFields()
        }

        coordinator.observeNotifications(for: container)
        return container
    }

    func updateUIView(_ uiView: LoginCredentialsContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // UIKit 持有输入值。SwiftUI 刷新只更新交互状态，不能回写可能早于系统填充的快照。
        if uiView.usernameField.isEnabled != isEnabled {
            uiView.usernameField.isEnabled = isEnabled
        }
        if uiView.passwordField.isEnabled != isEnabled {
            uiView.passwordField.isEnabled = isEnabled
        }
        if uiView.visibilityButton.isEnabled != isEnabled {
            uiView.visibilityButton.isEnabled = isEnabled
        }

        // 不在常规 updateUIView 中强行修改第一响应者，仅在点击提交时收起键盘。
        if dismissKeyboardToken != coordinator.lastDismissKeyboardToken {
            coordinator.lastDismissKeyboardToken = dismissKeyboardToken
            uiView.endEditing(true)
        }
    }

    static func dismantleUIView(_ uiView: LoginCredentialsContainerView, coordinator: Coordinator) {
        coordinator.container = nil
        uiView.usernameField.onTextMutation = nil
        uiView.passwordField.onTextMutation = nil
        uiView.passwordField.text = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LoginCredentialsCardView
        weak var container: LoginCredentialsContainerView?
        private var lastPublishedCredentials = LoginCredentials()
        private var isFieldSyncScheduled = false
        var lastDismissKeyboardToken = 0
        private var observers: [NSObjectProtocol] = []

        init(_ parent: LoginCredentialsCardView) {
            self.parent = parent
            self.lastDismissKeyboardToken = parent.dismissKeyboardToken
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observeNotifications(for container: LoginCredentialsContainerView) {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: UITextField.textDidChangeNotification,
                    object: container.usernameField,
                    queue: .main
                ) { [weak self] _ in self?.syncFromFields() },
                center.addObserver(
                    forName: UITextField.textDidChangeNotification,
                    object: container.passwordField,
                    queue: .main
                ) { [weak self] _ in self?.syncFromFields() },
            ]
        }

        @objc func fieldsDidChange() {
            syncFromFields()
        }

        func syncFromFields() {
            guard !isFieldSyncScheduled else { return }
            isFieldSyncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFieldSyncScheduled = false
                self.publishCurrentFields()
            }
        }

        private func publishCurrentFields() {
            guard let container else { return }
            // 系统可能先后写入两个字段。读取当前表单一次，将整组凭据一起发布。
            let credentials = LoginCredentials(
                username: container.usernameField.text ?? "",
                password: container.passwordField.text ?? ""
            )
            guard credentials != lastPublishedCredentials else { return }
            lastPublishedCredentials = credentials
            parent.onCredentialsChanged(credentials)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            syncFromFields()
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            syncFromFields()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            syncFromFields()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            syncFromFields()
            if textField === container?.usernameField {
                container?.passwordField.becomeFirstResponder()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onSubmit()
                }
            }
            return false
        }
    }
}

private struct NoveliaWebsiteLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AccountAuthStore
    let onBack: () -> Void
    @State private var loginCompletionTask: Task<Void, Never>?

    @State private var pageLoadError: String?

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: 0) {
                Text("在 Novelia 官网登录。若未自动显示登录框，请点击网页中的“登录/注册”。账号密码由官网直接处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                NoveliaAuthWebView(
                    appID: "n",
                    configuration: auth.configuration.authentication,
                    onLoginSuccess: { completeLogin() },
                    onLoadFailure: { message in
                        pageLoadError = message
                    }
                )
            }
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(auth.isRefreshing ? "验证中…" : "完成登录") {
                        completeLogin()
                    }
                    .disabled(auth.isRefreshing || loginCompletionTask != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let message = auth.errorMessage ?? pageLoadError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    Button("返回原生登录", action: onBack)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .disabled(auth.isRefreshing || loginCompletionTask != nil)
                }
                .background(.regularMaterial)
            }
        }
        .onAppear { auth.errorMessage = nil }
        .onDisappear { loginCompletionTask?.cancel() }
    }

    private func completeLogin() {
        guard loginCompletionTask == nil else { return }
        loginCompletionTask = Task { @MainActor in
            defer { loginCompletionTask = nil }
            do {
                // 等待 WebKit 更新响应 Cookie，再等待已有的
                // 续期任务完成，避免丢失本次登录成功信号。
                try await Task.sleep(nanoseconds: 150_000_000)
                while auth.isRefreshing {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                if await auth.establishUnifiedSession(usingWebsiteCookies: true), !Task.isCancelled { dismiss() }
            } catch { /* Closing the sheet cancels automatic completion. */ }
        }
    }

}

struct NoveliaAuthWebView: UIViewRepresentable {
    let appID: String
    let configuration: AuthenticationConfiguration
    let onLoginSuccess: () -> Void
    let onLoadFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, onLoginSuccess: onLoginSuccess, onLoadFailure: onLoadFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "noveliaAuth")
        // 使用官网现有登录表单；成功通知只触发原生 Cookie 续期，不读取账号密码。
        // 小说网页与认证 API 的来源分别配置并严格检查。
        let script = configuration.loginSuccessScript
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground

        view.load(URLRequest(url: self.configuration.loginURL(app: appID)))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onLoginSuccess = onLoginSuccess
        context.coordinator.onLoadFailure = onLoadFailure
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "noveliaAuth")
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let configuration: AuthenticationConfiguration
        var onLoginSuccess: () -> Void
        var onLoadFailure: (String) -> Void

        init(configuration: AuthenticationConfiguration, onLoginSuccess: @escaping () -> Void, onLoadFailure: @escaping (String) -> Void) {
            self.configuration = configuration
            self.onLoginSuccess = onLoginSuccess
            self.onLoadFailure = onLoadFailure
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "noveliaAuth",
                  message.frameInfo.isMainFrame,
                  configuration.trustsLoginPage(scheme: message.frameInfo.securityOrigin.protocol,
                                       host: message.frameInfo.securityOrigin.host,
                                       port: message.frameInfo.securityOrigin.port),
                  message.body as? String == "login_success" else { return }
            DispatchQueue.main.async { self.onLoginSuccess() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.onLoadFailure("认证页面加载失败：\(error.localizedDescription)（\(nsError.code)）")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 将安全的身份提供方重定向保留在同一个 WKWebView 中，
            // 使其完成登录流程并保留 Cookie 会话。
            guard url.scheme == "https" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

private struct ForumWebsiteLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: ForumAuthStore
    let onBack: () -> Void
    @State private var loginCompletionTask: Task<Void, Never>?

    @State private var pageLoadError: String?

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: 0) {
                Text("在 Novelia 官网登录同一个小说与论坛账号。若未显示登录框，请点击网页中的“登录/注册”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                NoveliaAuthWebView(appID: "f", configuration: auth.configuration.authentication, onLoginSuccess: {
                    completeLogin()
                }, onLoadFailure: { pageLoadError = $0 })
            }
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(auth.isRefreshing ? "验证中…" : "完成登录") {
                        completeLogin()
                    }
                    .disabled(auth.isRefreshing || loginCompletionTask != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let message = auth.errorMessage ?? pageLoadError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    Button("返回原生登录", action: onBack)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .disabled(auth.isRefreshing || loginCompletionTask != nil)
                }
                .background(.regularMaterial)
            }
        }
        .onAppear { auth.errorMessage = nil }
        .onDisappear { loginCompletionTask?.cancel() }
    }

    private func completeLogin() {
        guard loginCompletionTask == nil else { return }
        loginCompletionTask = Task { @MainActor in
            defer { loginCompletionTask = nil }
            do {
                // 等待 WebKit 更新响应 Cookie，再等待已有的
                // 续期任务完成，避免丢失本次登录成功信号。
                try await Task.sleep(nanoseconds: 150_000_000)
                while auth.isRefreshing {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                if await auth.establishUnifiedSession(usingWebsiteCookies: true), !Task.isCancelled { dismiss() }
            } catch { /* Closing the sheet cancels automatic completion. */ }
        }
    }

}
