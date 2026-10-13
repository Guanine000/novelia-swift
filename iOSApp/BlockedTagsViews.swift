import SwiftUI
import OSLog
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct BlockedTagsView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var newTag = ""
    var body: some View {
        Form {
            Section("添加屏蔽标签") {
                TextField("标签名称（精确匹配）", text: $newTag)
                Button("添加") { blocked.add(newTag); newTag = "" }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("已屏蔽标签") {
                if blocked.tags.isEmpty { Text("暂无屏蔽标签").foregroundStyle(.secondary) }
                ForEach(blocked.tags, id: \.self) { tag in
                    HStack {
                        Text(tag); Spacer()
                        Button("解除屏蔽") { blocked.remove(tag) }.buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Text("含任一屏蔽标签的作品会从发现、搜索和排行榜中隐藏；书库、收藏及下载不受影响。标签按完整名称匹配，设置保存在本机，也可通过手动 WebDAV 同步屏蔽和解除记录。文库列表不返回标签，只能过滤本机已查看过详情的作品。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("标签屏蔽")
    }
}

/// 作品详情页标签区的二级菜单：勾选屏蔽/解除本作品的标签，并保留进入标签屏蔽管理的入口。
struct TagBlockingMenu: View {
    let tags: [String]
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var showsManager = false

    var body: some View {
        Menu {
            ForEach(tags, id: \.self) { tag in
                Button {
                    if blocked.contains(tag) { blocked.remove(tag) } else { blocked.add(tag) }
                } label: {
                    Label(tag, systemImage: blocked.contains(tag) ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button { showsManager = true } label: {
                Label("标签屏蔽管理", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("选择标签屏蔽")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NoveliaStyle.brandGreen)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(NoveliaStyle.brandGreen.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $showsManager) { BlockedTagsView() }
    }
}
