import PhotosUI
import SwiftUI
import UIKit
import ImageIO

/// 修改文库与导入书籍在书库中显示的书名、作者、简介和封面。只改书库记录，不改书籍文件，
/// 阅读进度、书签与统计不受影响；修改会随 WebDAV 书籍同步到其他设备。
struct LibraryBookInfoEditor: View {
    let record: LocalWenkuEPUB
    let coverURL: URL?
    let onSave: (_ title: String, _ author: String, _ description: String, _ cover: WenkuLocalLibraryStore.CoverChange) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var bookDescription: String
    @State private var pickedItem: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var savedCover: UIImage?
    @State private var removesCover = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(record: LocalWenkuEPUB, coverURL: URL?,
         onSave: @escaping (String, String, String, WenkuLocalLibraryStore.CoverChange) async throws -> Void) {
        self.record = record
        self.coverURL = coverURL
        self.onSave = onSave
        _title = State(initialValue: record.title)
        _author = State(initialValue: record.author ?? "")
        _bookDescription = State(initialValue: record.bookDescription ?? "")
    }

    private var displayedCover: UIImage? {
        if let newCover { return newCover }
        return removesCover ? nil : savedCover
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        Group {
                            if let displayedCover {
                                Image(uiImage: displayedCover).resizable().scaledToFill()
                            } else {
                                Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(.secondarySystemBackground))
                            }
                        }
                        .frame(width: 84, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 12) {
                            PhotosPicker(selection: $pickedItem, matching: .images) {
                                Label("从相册选择", systemImage: "photo")
                            }
                            if displayedCover != nil {
                                Button("移除封面", role: .destructive) {
                                    newCover = nil
                                    pickedItem = nil
                                    removesCover = true
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("封面")
                }
                Section("书名") {
                    TextField("书名", text: $title, axis: .vertical)
                }
                Section("作者") {
                    TextField("作者", text: $author)
                }
                Section {
                    TextField("简介", text: $bookDescription, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("简介")
                } footer: {
                    Text("只修改书库中显示的信息，不改动书籍文件；导出的文件仍是原来的内容。开启 WebDAV 书籍同步时，修改会同步到其他设备。")
                }
            }
            .navigationTitle("编辑信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView("正在保存…") } }
            .interactiveDismissDisabled(isSaving)
            .task(id: coverURL) {
                savedCover = nil
                guard let coverURL else { return }
                let image = await Task.detached(priority: .utility) {
                    (try? Data(contentsOf: coverURL)).flatMap(Self.decodeCover)
                }.value
                guard !Task.isCancelled else { return }
                savedCover = image
            }
            .task(id: pickedItem) { await loadPickedImage() }
            .alert("无法保存", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadPickedImage() async {
        guard let pickedItem else { return }
        guard let data = try? await pickedItem.loadTransferable(type: Data.self) else {
            if !Task.isCancelled { errorMessage = "无法读取所选图片。" }
            return
        }
        let image = await Task.detached(priority: .userInitiated) { Self.decodeCover(data) }.value
        guard !Task.isCancelled else { return }
        guard let image else { errorMessage = "无法读取所选图片。"; return }
        newCover = image
        removesCover = false
    }

    /// 只解码长边 900 像素的缩略图，避免在主执行域解码原始大图再缩放。
    nonisolated private static func decodeCover(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func save() {
        let change: WenkuLocalLibraryStore.CoverChange = newCover.map { .replace($0) } ?? (removesCover ? .remove : .keep)
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await onSave(title, author, bookDescription, change)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
