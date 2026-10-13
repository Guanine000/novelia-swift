import Foundation

/// 底栏的页面。原始值保存在用户设备上，不能更改。
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case library
    case discover
    case community
    case me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "书库"
        case .discover: "发现"
        case .community: "社区"
        case .me: "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical.fill"
        case .discover: "sparkle.magnifyingglass"
        case .community: "bubble.left.and.bubble.right"
        case .me: "person.crop.circle"
        }
    }
}

/// 启动时打开的页面：固定某个页面，或上次使用的页面。
enum AppLaunchTab: Equatable, Hashable, Sendable {
    case fixed(AppTab)
    case lastUsed

    static let lastUsedRawValue = "last"
    static let `default` = AppLaunchTab.fixed(.library)

    init(rawValue: String?) {
        if rawValue == Self.lastUsedRawValue {
            self = .lastUsed
        } else if let rawValue, let tab = AppTab(rawValue: rawValue) {
            self = .fixed(tab)
        } else {
            self = .default
        }
    }

    var rawValue: String {
        switch self {
        case .fixed(let tab): tab.rawValue
        case .lastUsed: Self.lastUsedRawValue
        }
    }
}

enum AppTabLayout {
    static let defaultOrder = AppTab.allCases

    /// 读取保存的顺序：忽略未知值和重复项，并把缺少的页面按默认顺序补在末尾，
    /// 保证底栏始终包含全部页面且各出现一次。
    static func order(from stored: String?) -> [AppTab] {
        var result: [AppTab] = []
        for part in (stored ?? "").split(separator: ",") {
            if let tab = AppTab(rawValue: part.trimmingCharacters(in: .whitespaces)), !result.contains(tab) {
                result.append(tab)
            }
        }
        for tab in defaultOrder where !result.contains(tab) {
            result.append(tab)
        }
        return result
    }

    static func storedValue(for order: [AppTab]) -> String {
        self.order(from: order.map(\.rawValue).joined(separator: ",")).map(\.rawValue).joined(separator: ",")
    }

    /// 启动时选中的页面；“上次使用”没有记录时回到底栏第一项。
    static func initialTab(launch: AppLaunchTab, lastSelected: String?, order: [AppTab]) -> AppTab {
        switch launch {
        case .fixed(let tab): return tab
        case .lastUsed: return lastSelected.flatMap(AppTab.init(rawValue:)) ?? order.first ?? .library
        }
    }
}
