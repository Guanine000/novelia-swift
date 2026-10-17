import PhotosUI
import SwiftUI
import UIKit

/// 修改文库与导入书籍在书库中显示的书名、作者、简介和封面。只改书库记录，不改书籍文件，
/// 阅读进度、书签与统计不受影响；修改会随 WebDAV 书籍同步到其他设备。
struct LibraryBookInfoEditor: View {
    let record: LocalWenkuEPUB
    let coverURL: URL?
    let onSave: (_ title: String, _ author: String, _ description: String, _ cover: WenkuLocalLibraryStore.CoverChange) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var bookDescription: String
    @State private var pickedItem: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var removesCover = false
    @State private var errorMessage: String?

    init(record: LocalWenkuEPUB, coverURL: URL?,
         onSave: @escaping (String, String, String, WenkuLocalLibraryStore.CoverChange) throws -> Void) {
        self.record = record
        self.coverURL = coverURL
        self.onSave = onSave
        _title = State(initialValue: record.title)
        _author = State(initialValue: record.author ?? "")
        _bookDescription = State(initialValue: record.bookDescription ?? "")
    }

    private var existingCover: UIImage? {
        coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private var displayedCover: UIImage? {
        if let newCover { return newCover }
        return removesCover ? nil : existingCover
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
        guard let data = try? await pickedItem.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            errorMessage = "无法读取所选图片。"
            return
        }
        newCover = Self.downscaled(image)
        removesCover = false
    }

    /// 封面只在列表中小尺寸显示，缩到长边 900 像素以内，避免占用过多空间和同步流量。
    private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > 900 else { return image }
        let factor = 900 / longest
        let size = CGSize(width: image.size.width * image.scale * factor, height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private func save() {
        let change: WenkuLocalLibraryStore.CoverChange = newCover.map { .replace($0) } ?? (removesCover ? .remove : .keep)
        do {
            try onSave(title, author, bookDescription, change)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
