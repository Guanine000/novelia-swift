import SwiftUI
import UniformTypeIdentifiers

// MARK: - 原型阅读界面
//
// 纵向切片入口：打开一份本地 EPUB（默认生成样例书），用 CoreText 分页 +
// 左右相接平移翻页验证"预览 = 落页"。工具栏提供目录跳转与字号调整，
// 两者都会明确使当前分页代次失效并重排。

struct PrototypeReaderView: View {
    @StateObject private var model = PrototypeReaderModel()
    @State private var isShowingTOC = false
    let bookURL: URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.97, green: 0.95, blue: 0.91).ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView("正在解析 EPUB…")
                case .failed(let message):
                    ContentUnavailableView("无法排版", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    PrototypePagerView(
                        canTurn: { forward in model.canTurn(forward: forward) },
                        onCommit: { forward in
                            model.commitTurn(forward: forward)
                        },
                        onAnimatingChange: { animating in model.setAnimating(animating) },
                        images: model.pagerImages()
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if model.isLayingOut {
                    ProgressView().scaleEffect(1.4)
                        .padding(22)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                model.viewportSize = newSize
            }
            .onAppear {
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
                if model.status == .idle, let bookURL {
                    Task { await model.open(url: bookURL) }
                }
            }
        }
        .navigationTitle(model.container?.bookTitle ?? "排版原型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("目录") { isShowingTOC = true }
                    .disabled(model.container == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        model.setFontSize(model.fontSize - 1)
                    } label: { Image(systemName: "textformat.size.smaller") }
                    Button {
                        model.setFontSize(model.fontSize + 1)
                    } label: { Image(systemName: "textformat.size.larger") }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    model.commitTurn(forward: false)
                } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canTurn(forward: false))
                Spacer()
                Text(model.locationDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.commitTurn(forward: true)
                } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canTurn(forward: true))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $isShowingTOC) {
            NavigationStack {
                List(model.container?.toc ?? []) { entry in
                    Button {
                        isShowingTOC = false
                        model.jump(to: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).foregroundStyle(.primary)
                            if let spineIndex = entry.spineIndex {
                                Text("spine \(spineIndex + 1)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - 打开入口（注入样例书或指定 EPUB）

struct PrototypeReaderHost: View {
    let initialURL: URL?
    @State private var resolvedURL: URL?

    var body: some View {
        Group {
            if let resolvedURL {
                PrototypeReaderView(bookURL: resolvedURL)
            } else {
                ProgressView("准备样例书…")
            }
        }
        .task {
            if resolvedURL == nil {
                if let initialURL {
                    resolvedURL = initialURL
                } else {
                    resolvedURL = try? await PrototypeSampleBook.sampleURL()
                }
            }
        }
    }
}
