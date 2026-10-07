import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit

@MainActor
private final class WenkuEPUBReaderModel: ObservableObject, EPUBNavigatorDelegate {
    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var publication: Publication?
    @Published private(set) var tableOfContents: [WenkuEPUBTOCEntry] = []
    @Published private(set) var errorMessage: String?
    private var onLocationChanged: ((Locator) -> Void)?

    func open(_ url: URL, initialLocatorJSON: String?, onLocationChanged: @escaping (Locator) -> Void) async {
        errorMessage = nil
        self.onLocationChanged = onLocationChanged
        do {
            let httpClient = DefaultHTTPClient()
            let assetRetriever = AssetRetriever(httpClient: httpClient)
            let opener = PublicationOpener(
                parser: DefaultPublicationParser(
                    httpClient: httpClient,
                    assetRetriever: assetRetriever,
                    pdfFactory: DefaultPDFDocumentFactory()
                )
            )
            guard let fileURL = FileURL(url: url) else {
                throw WenkuEPUBReaderError.invalidURL
            }
            let asset = try await assetRetriever.retrieve(url: fileURL).get()
            let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
            guard publication.conforms(to: .epub) else {
                throw WenkuEPUBReaderError.unsupportedPublication
            }
            let initialLocation: Locator? = {
                guard let initialLocatorJSON,
                      let json = try? JSONValue(jsonString: initialLocatorJSON) else { return nil }
                return try? Locator(json: json, warnings: nil)
            }()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: EPUBNavigatorViewController.Configuration()
            )
            navigator.delegate = self
            self.publication = publication
            self.navigator = navigator
            let toc = (try? await publication.tableOfContents().get()) ?? publication.readingOrder
            tableOfContents = Self.flatten(toc)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func go(to link: ReadiumShared.Link) async {
        guard let navigator else { return }
        _ = await navigator.go(to: link, options: .animated)
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChanged?(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = "EPUB 阅读器发生错误：\(error)"
    }

    private static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [WenkuEPUBTOCEntry] {
        links.flatMap { link in
            [WenkuEPUBTOCEntry(id: "\(depth)-\(link.href)", link: link, depth: depth)]
                + flatten(link.children, depth: depth + 1)
        }
    }
}

private struct WenkuEPUBTOCEntry: Identifiable {
    let id: String
    let link: ReadiumShared.Link
    let depth: Int
}

struct WenkuEPUBReaderView: View {
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    let book: LocalWenkuEPUB
    let url: URL

    @StateObject private var model = WenkuEPUBReaderModel()
    @State private var isShowingTOC = false

    var body: some View {
        Group {
            if let navigator = model.navigator {
                ReadiumNavigatorContainer(navigator: navigator)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = model.errorMessage {
                ContentUnavailableView("无法打开 EPUB", systemImage: "book.closed", description: Text(error))
            } else {
                ProgressView("正在解析 EPUB…")
            }
        }
        .navigationTitle(model.publication?.metadata.title ?? book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isShowingTOC = true } label: { Image(systemName: "list.bullet") }
                    .disabled(model.navigator == nil || model.tableOfContents.isEmpty)
                    .accessibilityLabel("目录")
            }
        }
        .sheet(isPresented: $isShowingTOC) {
            NavigationStack {
                List(model.tableOfContents) { entry in
                    Button {
                        Task {
                            await model.go(to: entry.link)
                            isShowingTOC = false
                        }
                    } label: {
                        Text(entry.link.title ?? entry.link.href)
                            .padding(.leading, CGFloat(entry.depth) * 14)
                            .foregroundStyle(NoveliaStyle.ink)
                    }
                }
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { isShowingTOC = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: url) {
            await model.open(url, initialLocatorJSON: book.lastLocatorJSON) { locator in
                guard let json = try? locator.jsonString() else { return }
                localLibrary.updateReadingLocation(bookID: book.id, locatorJSON: json)
            }
        }
    }
}

private struct ReadiumNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}

private enum WenkuEPUBReaderError: LocalizedError {
    case invalidURL
    case unsupportedPublication

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无法读取本地 EPUB 文件路径。"
        case .unsupportedPublication: "该文件不是 Readium 支持的 EPUB。"
        }
    }
}
