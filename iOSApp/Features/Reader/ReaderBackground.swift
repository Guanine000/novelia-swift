import SwiftUI
import OSLog
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class ReaderBackgroundStore: ObservableObject {
    static let shared = ReaderBackgroundStore()
    @Published private(set) var revision = 0
    private var images: [String: UIImage] = [:]
    private let defaults: UserDefaults
    private let directory: URL
    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderBackgrounds", isDirectory: true)
    }
    private func key(_ dark: Bool, _ field: String) -> String { "readerBackground.\(dark ? "dark" : "light").\(field)" }
    func mode(dark: Bool) -> String { defaults.string(forKey: key(dark, "mode")) ?? "default" }
    func hex(dark: Bool) -> String { defaults.string(forKey: key(dark, "color")) ?? (dark ? "19191C" : "FAF7F0") }
    func color(dark: Bool, fallback: Color) -> Color { mode(dark: dark) == "default" ? fallback : AppThemeColor.color(fromHex: hex(dark: dark)) }
    func setMode(_ mode: String, dark: Bool) { defaults.set(mode, forKey: key(dark, "mode")); defaults.set(Date(), forKey: key(dark, "updatedAt")); revision += 1 }
    func setColor(_ color: Color, dark: Bool) { defaults.set(AppThemeColor.hex(from: color), forKey: key(dark, "color")); setMode("color", dark: dark) }
    func imageURL(dark: Bool, landscape: Bool = false) -> URL {
        directory.appendingPathComponent("\(dark ? "dark" : "light")\(landscape ? "-landscape" : "").jpg")
    }
    func image(dark: Bool, landscape: Bool = false) -> UIImage? {
        guard mode(dark: dark) == "image" else { return nil }
        let cacheKey = "\(dark)-\(landscape)"
        if let image = images[cacheKey] { return image }
        let image = UIImage(contentsOfFile: imageURL(dark: dark, landscape: landscape).path)
        images[cacheKey] = image
        return image
    }
    func importImage(_ data: Data, dark: Bool, landscape: Bool = false) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "ReaderBackground", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取这张图片，请选择其他图片。"])
        }
        let url = imageURL(dark: dark, landscape: landscape)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        images["\(dark)-\(landscape)"] = UIImage(cgImage: cg)
        setMode("image", dark: dark)
    }
    func restoreDefaultColor(dark: Bool) {
        defaults.removeObject(forKey: key(dark, "color"))
        setMode(mode(dark: dark) == "color" ? "default" : mode(dark: dark), dark: dark)
    }
    func restoreDefaults(dark: Bool) throws {
        for landscape in [false, true] {
            let url = imageURL(dark: dark, landscape: landscape)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        defaults.removeObject(forKey: key(dark, "color"))
        images.removeAll()
        setMode("default", dark: dark)
    }
    func removeImage(dark: Bool, landscape: Bool = false) throws {
        let url = imageURL(dark: dark, landscape: landscape)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        images["\(dark)-\(landscape)"] = nil
        defaults.set(Date(), forKey: key(dark, "updatedAt")); revision += 1
    }
}

struct ReaderBackgroundView: View {
    @EnvironmentObject private var store: ReaderBackgroundStore
    let dark: Bool
    let fallback: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                store.color(dark: dark, fallback: fallback)
                if let image = store.image(dark: dark, landscape: geometry.size.width > geometry.size.height) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ReaderBackgroundSettingsView: View {
    @EnvironmentObject private var store: ReaderBackgroundStore
    @State private var dark = false
    @State private var landscape = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section {
                Picker("配置模式", selection: $dark) {
                    Text("浅色模式").tag(false); Text("深色模式").tag(true)
                }.pickerStyle(.segmented).disabled(busy)
                Picker("图片方向", selection: $landscape) { Text("竖屏").tag(false); Text("横屏").tag(true) }.pickerStyle(.segmented).disabled(busy)
                Picker("背景类型", selection: Binding(get: { store.mode(dark: dark) }, set: { store.setMode($0, dark: dark) })) {
                    Text("默认").tag("default"); Text("自定义颜色").tag("color"); Text("图片").tag("image")
                }
                ColorPicker("自定义背景颜色", selection: Binding(
                    get: { AppThemeColor.color(fromHex: store.hex(dark: dark)) },
                    set: { store.setColor($0, dark: dark) }), supportsOpacity: false)
                Button("恢复默认颜色") { store.restoreDefaultColor(dark: dark); error = nil }.disabled(busy)
                PhotosPicker("从照片选择图片", selection: $selectedPhoto, matching: .images).disabled(busy)
                Button("从文件导入图片") { importing = true }.disabled(busy)
                Button("移除当前方向图片", role: .destructive) {
                    do { try store.removeImage(dark: dark, landscape: landscape) } catch { self.error = error.localizedDescription }
                }
                Button("恢复当前模式默认背景", role: .destructive) {
                    do { try store.restoreDefaults(dark: dark); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(busy)
                if busy { ProgressView("正在导入…") }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("默认：使用阅读器内置底色，不显示自定义颜色或图片，已导入图片仍保留。恢复默认颜色只重置颜色；恢复当前模式默认背景会清除该模式的颜色和两张图片。浅色和深色分别保存，随阅读器外观切换。竖屏与横屏图片分别保存；未设置当前方向图片时使用背景颜色。图片居中裁剪填满阅读区域；请选择与文字有足够对比的背景。设置应用于在线小说、TXT和EPUB，保存在本机。")
            }
            Section("预览") {
                ReaderBackgroundView(dark: dark, fallback: dark ? .black : NoveliaStyle.paper)
                    .overlay { Text("阅读背景预览\n正文示例").foregroundStyle(dark ? .white : .black) }
                    .frame(width: landscape ? 280 : 160, height: landscape ? 160 : 280).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("阅读背景")
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            let target = dark; let targetLandscape = landscape; busy = true; error = nil
            Task {
                defer { busy = false; selectedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    try store.importImage(data, dark: target, landscape: targetLandscape)
                } catch { self.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try store.importImage(Data(contentsOf: url), dark: dark, landscape: landscape); error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
extension ReaderBackgroundStore {
    func syncSnapshot(dark: Bool) throws -> SyncedReaderBackground {
        func hash(_ landscape: Bool) throws -> String? {
            let url = imageURL(dark: dark, landscape: landscape)
            return FileManager.default.fileExists(atPath: url.path) ? try FileContentHash.sha256(url) : nil
        }
        return try SyncedReaderBackground(mode: mode(dark: dark), color: hex(dark: dark), portraitHash: hash(false), landscapeHash: hash(true), updatedAt: defaults.object(forKey: key(dark, "updatedAt")) as? Date ?? .distantPast)
    }
    func applySync(_ value: SyncedReaderBackground, dark: Bool, files: [String: URL]) throws {
        guard value.updatedAt > (defaults.object(forKey: key(dark, "updatedAt")) as? Date ?? .distantPast) else { return }
        guard ["default", "color", "image"].contains(value.mode), value.color.count == 6, value.color.allSatisfy(\.isHexDigit) else { return }
        for (landscape, hash) in [(false, value.portraitHash), (true, value.landscapeHash)] {
            let target = imageURL(dark: dark, landscape: landscape)
            if let hash {
                guard let file = files[hash], UIImage(contentsOfFile: file.path) != nil else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(contentsOf: file).write(to: target, options: .atomic)
            } else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        defaults.set(value.mode, forKey: key(dark, "mode")); defaults.set(value.color, forKey: key(dark, "color"))
        defaults.set(value.updatedAt, forKey: key(dark, "updatedAt")); images.removeAll(); revision += 1
    }
}
