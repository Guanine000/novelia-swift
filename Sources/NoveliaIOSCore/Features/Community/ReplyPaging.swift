import Foundation

/// 论坛评论与小说书评的“加载更多回复”。页码按已请求的页数逐页前进，不按已显示数量推算：
/// 预览回复与分页的顺序可能不同，按数量推算会反复请求同一页而没有进展。
/// 新页与已显示的回复（含预览）按 ID 去重；返回不足一页时视为已到末尾。
struct ReplyPaging: Equatable {
    /// 下一次请求的页序号，从 0 开始；1 起始的接口调用时加 1。
    private(set) var nextPage = 0
    private(set) var isExhausted = false

    mutating func accept<Item: Identifiable>(_ page: [Item], shown: [Item], pageSize: Int) -> [Item] {
        nextPage += 1
        if page.count < pageSize { isExhausted = true }
        var known = Set(shown.map(\.id))
        return page.filter { known.insert($0.id).inserted }
    }
}
