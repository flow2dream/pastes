//
//  LocalizationManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI

enum AppLanguage: String, CaseIterable {
    case en = "en"
    case zh = "zh-Hans"

    var displayName: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }
}

final class LocalizationManager {
    static let shared = LocalizationManager()

    @AppStorage("appLanguage") var language: AppLanguage = .zh

    private init() {}

    func localized(_ key: String) -> String {
        switch language {
        case .zh: return Self.zh[key] ?? key
        case .en: return Self.en[key] ?? key
        }
    }

    // MARK: - Translations

    private static let en: [String: String] = [
        // App
        "app_name": "Pastes",
        "items_count": "%d items",

        // Search
        "search_placeholder": "Search clipboard history...",

        // Empty state
        "empty_title": "No clipboard history",
        "empty_search": "No results",
        "empty_hint": "Copy something to get started",

        // Actions
        "pin": "Pin",
        "unpin": "Unpin",
        "delete": "Delete",
        "copy": "Copy",

        // Header
        "clear_all": "Clear All",
        "pin_panel": "Pin window",
        "unpin_panel": "Unpin window",

        // Context menu
        "context_copy": "Copy",
        "context_pin": "Pin",
        "context_unpin": "Unpin",
        "context_delete": "Delete",

        // Settings
        "settings_title": "Settings",
        "hotkey_title": "Global Hotkey",
        "hotkey_desc": "Press this shortcut to show/hide the clipboard window from anywhere.",
        "hotkey_recording": "Press a key combination...",
        "hotkey_cancel": "Cancel",
        "hotkey_reset": "Reset",
        "hotkey_hint": "Click the field above, then press your desired shortcut.",
        "hotkey_conflict_title": "Shortcut Conflict",
        "hotkey_conflict_msg": "This shortcut is used by the system. Please choose a different one.",
        "hotkey_conflict_ok": "OK",
        "history_limit_title": "History Limit",
        "history_limit_desc": "Maximum number of clipboard items to keep. Oldest items are removed when the limit is reached. Set 0 for unlimited.",
        "history_limit_items": "items",
        "language_title": "Language",
        "language_desc": "Choose the display language for the app.",
        "launch_at_login_title": "Launch at Login",
        "launch_at_login_desc": "Automatically open Pastes when you log in to your Mac.",
        "launch_at_login_toggle": "Launch at login",
        "update_title": "Updates",
        "update_desc": "Automatically check for new versions of Pastes.",
        "auto_check_update": "Automatically check for updates",
        "check_update_now": "Check for Updates",
        "no_update_title": "No Updates",
        "no_update_msg": "You are running the latest version of Pastes.",
        "no_update_ok": "OK",
        "tips_title": "Tips",
        "tip_modifier": "Include at least one modifier key (⌘⌥⌃⇧)",
        "tip_global": "The shortcut works globally, even when the app is hidden",
        "tip_default": "Default shortcut is ⌘⇧V",

        // Menu
        "quit_app": "Quit Pastes",
    ]

    private static let zh: [String: String] = [
        // App
        "app_name": "剪贴板",
        "items_count": "%d 条记录",

        // Search
        "search_placeholder": "搜索剪贴板历史...",

        // Empty state
        "empty_title": "暂无剪贴板记录",
        "empty_search": "无匹配结果",
        "empty_hint": "复制一些内容开始使用",

        // Actions
        "pin": "固定",
        "unpin": "取消固定",
        "delete": "删除",
        "copy": "复制",

        // Header
        "clear_all": "清除全部",
        "pin_panel": "置顶窗口",
        "unpin_panel": "取消置顶",

        // Context menu
        "context_copy": "复制",
        "context_pin": "固定",
        "context_unpin": "取消固定",
        "context_delete": "删除",

        // Settings
        "settings_title": "设置",
        "hotkey_title": "全局快捷键",
        "hotkey_desc": "使用此快捷键在任何位置显示/隐藏剪贴板窗口。",
        "hotkey_recording": "请按下快捷键组合...",
        "hotkey_cancel": "取消",
        "hotkey_reset": "重置",
        "hotkey_hint": "点击上方输入框，然后按下您想要的快捷键。",
        "hotkey_conflict_title": "快捷键冲突",
        "hotkey_conflict_msg": "该快捷键与系统快捷键冲突，请重新设置。",
        "hotkey_conflict_ok": "好的",
        "history_limit_title": "历史记录上限",
        "history_limit_desc": "保留的最大剪贴板条目数。超出上限时将删除最早的记录。设为 0 表示无限制。",
        "history_limit_items": "条",
        "language_title": "语言",
        "language_desc": "选择应用的显示语言。",
        "launch_at_login_title": "开机自启",
        "launch_at_login_desc": "登录 Mac 时自动启动剪贴板。",
        "launch_at_login_toggle": "开机自启",
        "update_title": "更新",
        "update_desc": "自动检查 Pastes 的新版本。",
        "auto_check_update": "自动检查更新",
        "check_update_now": "检查更新",
        "no_update_title": "没有更新",
        "no_update_msg": "你正在使用最新版本的 Pastes。",
        "no_update_ok": "好的",
        "tips_title": "提示",
        "tip_modifier": "至少包含一个修饰键 (⌘⌥⌃⇧)",
        "tip_global": "快捷键全局生效，即使应用处于隐藏状态",
        "tip_default": "默认快捷键为 ⌘⇧V",

        // Menu
        "quit_app": "退出剪贴板",
    ]
}

// MARK: - Convenience

func L(_ key: String) -> String {
    LocalizationManager.shared.localized(key)
}
