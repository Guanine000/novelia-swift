import SwiftUI
import UIKit

// MARK: - 书内图片：图片库、查看器与目录页图片网格
//
// YueduCoreText 与 Readium 阅读器共用。图片一律经 `EPUBContainer` 从 ZIP 读取原始数据，
// 与排版引擎持有的位图无关：查看器按需解码大图，网格只解码缩略图。
// 全书图片列表需要读取所有章节，首次进入“图片”页或首次点图时在后台收集，之后复用。

/// 一本书的图片来源与解码缓存；实例由阅读器模型持有，书籍打开后挂上容器。
@MainActor
final class ReaderImageLibrary: ObservableObject {
    /// 一次查看器展示：从 `startIndex` 开始，可左右切换 `images`。
    struct Presentation: Identifiable {
        let id = UUID()
        let images: [EPUBImageEntry]
        let startIndex: Int
    }

    /// 全书图片；nil 表示尚未收集。
    @Published private(set) var images: [EPUBImageEntry]?
    @Published private(set) var isLoading = false
    /// 阅读页点图后的展示（目录页网格自行管理展示，避免与已弹出的目录面板冲突）。
    @Published var presentation: Presentation?

    private var container: EPUBContainer?
    private var loadTask: Task<[EPUBImageEntry], Never>?
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 120
    }

    /// 只有 EPUB 有图片来源；TXT 与在线小说不挂容器。
    var isAvailable: Bool { container != nil }

    func attach(_ container: EPUBContainer?) {
        loadTask?.cancel()
        loadTask = nil
        self.container = container
        images = nil
        isLoading = false
        cache.removeAllObjects()
    }

    /// 收集全书图片（只收集一次；并发调用共享同一任务）。
    @discardableResult
    func loadIfNeeded() async -> [EPUBImageEntry] {
        if let images { return images }
        guard let container else { return [] }
        if let loadTask { return await loadTask.value }
        isLoading = true
        let task = Task { await container.allImages() }
        loadTask = task
        let result = await task.value
        guard self.container === container, !task.isCancelled else { return result }
        images = result
        isLoading = false
        loadTask = nil
        return result
    }

    /// 阅读页点到图片：列表已收集时可左右切换全书图片，否则先只显示这一张，并在后台收集列表。
    func presentTapped(path: String) {
        if let images, let index = images.firstIndex(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
            presentation = Presentation(images: images, startIndex: index)
        } else {
            presentation = Presentation(images: [EPUBImageEntry(path: path, spineIndex: nil)], startIndex: 0)
            Task { await loadIfNeeded() }
        }
    }

    /// 解码图片；`maxPixelLength` 为 nil 时按原尺寸。解码在后台进行，结果按尺寸缓存。
    func image(path: String, maxPixelLength: CGFloat?) async -> UIImage? {
        let key = "\(path)#\(Int(maxPixelLength ?? 0))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let container, let data = await container.entryData(atPath: path) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            EPUBImageDecoding.image(from: data, maxPixelLength: maxPixelLength)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// 在阅读页上呈现 `ReaderImageLibrary.presentation`（需要观察图片库本身，模型变化不会通知到它）。
struct ReaderImagePresenter: ViewModifier {
    @ObservedObject var library: ReaderImageLibrary
    let chapterTitle: (Int) -> String?
    let onJump: (EPUBImageEntry) -> Void

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $library.presentation) { presentation in
            ReaderImageViewer(library: library, presentation: presentation, chapterTitle: chapterTitle) { entry in
                library.presentation = nil
                onJump(entry)
            }
        }
    }
}

// MARK: - 查看器

/// 全屏图片查看：双指缩放、双击放大／还原、左右切换；单击显隐顶部与底部按钮。
struct ReaderImageViewer: View {
    @ObservedObject var library: ReaderImageLibrary
    let presentation: ReaderImageLibrary.Presentation
    let chapterTitle: (Int) -> String?
    /// 跳到图片在正文中的位置；由呈现方关闭查看器（及目录面板）后跳转。
    let onJump: (EPUBImageEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showsChrome = true
    @State private var sharedImage: UIImage?

    private var current: EPUBImageEntry? {
        presentation.images.indices.contains(index) ? presentation.images[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(presentation.images.indices, id: \.self) { position in
                    ReaderZoomableImagePage(library: library, path: presentation.images[position].path) {
                        withAnimation(.easeInOut(duration: 0.15)) { showsChrome.toggle() }
                    }
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showsChrome {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("关闭")
                        Spacer()
                        if presentation.images.count > 1 {
                            Text("\(index + 1) / \(presentation.images.count)")
                                .font(.subheadline.monospacedDigit())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Button {
                            guard let path = current?.path else { return }
                            Task { sharedImage = await library.image(path: path, maxPixelLength: nil) }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("分享或保存")
                    }
                    .padding(.horizontal, 16)
                    Spacer()
                    if let entry = current, let spine = entry.spineIndex {
                        Button {
                            onJump(entry)
                        } label: {
                            Label(chapterTitle(spine).map { "跳到原文位置 · \($0)" } ?? "跳到原文位置",
                                  systemImage: "arrow.uturn.forward")
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.bottom, 12)
                    }
                }
                .foregroundStyle(.white)
                .tint(.white)
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showsChrome)
        .onAppear { index = presentation.startIndex }
        .sheet(isPresented: Binding(get: { sharedImage != nil }, set: { if !$0 { sharedImage = nil } })) {
            if let sharedImage { ReaderActivityView(items: [sharedImage]) }
        }
    }
}

/// 查看器中的一页：加载中显示进度，加载失败显示说明。
private struct ReaderZoomableImagePage: View {
    @ObservedObject var library: ReaderImageLibrary
    let path: String
    let onSingleTap: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ReaderZoomableImageView(image: image, onSingleTap: onSingleTap)
            } else if failed {
                ContentUnavailableView("无法读取图片", systemImage: "photo.badge.exclamationmark",
                                       description: Text(path))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSingleTap)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: path) {
            // 长边限制在 4096 像素：放大查看仍清晰，又不让超大插图占满内存。
            image = await library.image(path: path, maxPixelLength: 4096)
            failed = image == nil
        }
    }
}

/// `UIScrollView` 缩放：1～5 倍，双击在点按位置放大到 2.5 倍或还原，缩放后图片保持居中。
private struct ReaderZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    func makeUIView(context: Context) -> CenteringScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.imageView.image = image
        scrollView.imageView.contentMode = .scaleAspectFit

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: CenteringScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if scrollView.imageView.image !== image {
            scrollView.imageView.image = image
            scrollView.setZoomScale(1, animated: false)
            scrollView.setNeedsLayout()
        }
    }

    final class CenteringScrollView: UIScrollView {
        let imageView = UIImageView()
        private var lastBoundsSize: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 尺寸变化（旋转）时按新视口重新适配；缩放中只调整居中边距。
            if bounds.size != lastBoundsSize {
                lastBoundsSize = bounds.size
                setZoomScale(1, animated: false)
                imageView.frame = fittedFrame()
                contentSize = imageView.frame.size
            }
            centerContent()
        }

        private func fittedFrame() -> CGRect {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return bounds }
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            return CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        }

        func centerContent() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) { self.onSingleTap = onSingleTap }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.centerContent()
        }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? CenteringScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: scrollView.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// 系统分享面板（可存储到相册、拷贝或发送）。
private struct ReaderActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 目录页“图片”网格

/// 目录面板顶部的切换：章节目录或全书图片。
enum ReaderTOCTab: Hashable {
    case contents, images
}

struct ReaderTOCTabPicker: View {
    @Binding var selection: ReaderTOCTab

    var body: some View {
        Picker("目录内容", selection: $selection) {
            Text("目录").tag(ReaderTOCTab.contents)
            Text("图片").tag(ReaderTOCTab.images)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
    }
}

/// 全书图片缩略图；点按打开查看器，可从查看器跳到图片在正文中的位置。
struct ReaderImageGallery: View {
    @ObservedObject var library: ReaderImageLibrary
    let chapterTitle: (Int) -> String?
    /// 跳到图片位置：由目录面板关闭自身后执行。
    let onJump: (EPUBImageEntry) -> Void
    @State private var presentation: ReaderImageLibrary.Presentation?

    var body: some View {
        Group {
            if let images = library.images {
                if images.isEmpty {
                    ContentUnavailableView("没有图片", systemImage: "photo.on.rectangle",
                                           description: Text("本书正文中没有可查看的插图。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 14) {
                            ForEach(images.indices, id: \.self) { index in
                                Button {
                                    presentation = ReaderImageLibrary.Presentation(images: images, startIndex: index)
                                } label: {
                                    ReaderImageThumbnail(library: library, entry: images[index],
                                                         caption: images[index].spineIndex.flatMap(chapterTitle))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ProgressView("正在查找图片…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await library.loadIfNeeded() }
        .fullScreenCover(item: $presentation) { presentation in
            ReaderImageViewer(library: library, presentation: presentation, chapterTitle: chapterTitle) { entry in
                self.presentation = nil
                onJump(entry)
            }
        }
    }
}

private struct ReaderImageThumbnail: View {
    @ObservedObject var library: ReaderImageLibrary
    let entry: EPUBImageEntry
    let caption: String?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Color(uiColor: .secondarySystemBackground)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: entry.path) {
            image = await library.image(path: entry.path, maxPixelLength: 160 * displayScale)
        }
    }
}
