//
//  LocalizationManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI

enum AppLanguage: String, CaseIterable {
    case en = "en"
    case zh = "zh_CN"

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
        if key == "tip_default" {
            let shortcut = HotkeyManager.defaultDisplayString
            return language == .zh ? "默认快捷键为 \(shortcut)" : "Default shortcut is \(shortcut)"
        }
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
        "clear_unpinned": "Clear unpinned history",
        "clear_search": "Clear search",
        "history_pinned": "Pinned",
        "history_recent": "Recent",
        "history_copy_hint": "Click to copy",
        "record_text": "Text",
        "record_rich_text": "Rich text",
        "record_image": "Image",
        "empty_search_hint": "Try another search.",
        "pin_panel": "Pin window",
        "unpin_panel": "Unpin window",

        // Context menu
        "context_copy": "Copy",
        "context_pin": "Pin",
        "context_unpin": "Unpin",
        "context_delete": "Delete",

        // Settings
        "settings_title": "Settings",
        "settings_general": "General",
        "settings_system": "System",
        "history_limit_compact_hint": "0 means unlimited",
        "hotkey_show_panel": "Show clipboard",
        "hotkey_default_label": "Default",
        "login_pending_status": "Pending approval",
        "settings_auto_paste": "Automatic paste",
        "accessibility_status_granted": "Allowed",
        "accessibility_status_required": "Not allowed",
        "hotkey_title": "Global Hotkey",
        "hotkey_desc": "Press this shortcut to show/hide the clipboard window from anywhere.",
        "hotkey_recording": "Press a key combination...",
        "hotkey_cancel": "Cancel",
        "hotkey_reset": "Reset",
        "hotkey_hint": "Click the field above, then press your desired shortcut.",
        "hotkey_conflict_title": "Shortcut Conflict",
        "hotkey_conflict_msg": "This shortcut is used by the system. Please choose a different one.",
        "hotkey_conflict_ok": "OK",
        "hotkey_registration_failed": "Could not register this shortcut. It may already be in use.",
        "hotkey_handler_failed": "Could not start the global shortcut handler.",
        "history_limit_title": "History Limit",
        "history_limit_desc": "Maximum number of clipboard items to keep. Oldest items are removed when the limit is reached. Set 0 for unlimited.",
        "history_limit_items": "items",
        "language_title": "Language",
        "language_desc": "Choose the display language for the app.",
        "launch_at_login_title": "Launch at Login",
        "launch_at_login_desc": "Automatically open Pastes when you log in to your Mac.",
        "launch_at_login_toggle": "Launch at login",
        "login_approval_required": "Allow Pastes in System Settings to complete login item setup.",
        "login_open_settings": "Open Login Items Settings",
        "login_change_failed": "Could not change the login item:",
        "accessibility_title": "Automatic Paste Permission",
        "accessibility_enabled": "System keyboard control is allowed. Automatic paste is available.",
        "accessibility_required": "Automatic paste requires system keyboard control permission. Copying history items still works.",
        "accessibility_open_settings": "Open Permission Settings",
        "paste_permission_required": "Copied. You can paste with ⌘V. Automatic paste requires system keyboard control permission.",
        "paste_permission_settings": "Permissions",
        "update_title": "Updates",
        "update_desc": "Check for new versions of Pastes.",
        "update_development_desc": "Automatic updates are disabled for development builds.",
        "update_start_failed": "Could not start the updater:",
        "clipboard_error_title": "Could not copy clipboard content",
        "storage_error_title": "Clipboard storage error",
        "storage_open_error": "Unable to open clipboard history. Your existing files have been preserved.",
        "check_update_now": "Check for Updates",
        "version_label": "Version",
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
        "clear_unpinned": "清除未固定的历史记录",
        "clear_search": "清除搜索",
        "history_pinned": "已固定",
        "history_recent": "最近记录",
        "history_copy_hint": "点击复制",
        "record_text": "文本",
        "record_rich_text": "富文本",
        "record_image": "图片",
        "empty_search_hint": "试试其他关键词。",
        "pin_panel": "置顶窗口",
        "unpin_panel": "取消置顶",

        // Context menu
        "context_copy": "复制",
        "context_pin": "固定",
        "context_unpin": "取消固定",
        "context_delete": "删除",

        // Settings
        "settings_title": "设置",
        "settings_general": "常规",
        "settings_system": "系统",
        "history_limit_compact_hint": "0 表示不限",
        "hotkey_show_panel": "显示剪贴板",
        "hotkey_default_label": "默认",
        "login_pending_status": "待批准",
        "settings_auto_paste": "自动粘贴",
        "accessibility_status_granted": "已允许",
        "accessibility_status_required": "未授权",
        "hotkey_title": "全局快捷键",
        "hotkey_desc": "使用此快捷键在任何位置显示/隐藏剪贴板窗口。",
        "hotkey_recording": "请按下快捷键组合...",
        "hotkey_cancel": "取消",
        "hotkey_reset": "重置",
        "hotkey_hint": "点击上方输入框，然后按下您想要的快捷键。",
        "hotkey_conflict_title": "快捷键冲突",
        "hotkey_conflict_msg": "该快捷键与系统快捷键冲突，请重新设置。",
        "hotkey_conflict_ok": "好的",
        "hotkey_registration_failed": "无法注册此快捷键，可能已被其他应用占用。",
        "hotkey_handler_failed": "无法启动全局快捷键监听。",
        "history_limit_title": "历史记录上限",
        "history_limit_desc": "保留的最大剪贴板条目数。超出上限时将删除最早的记录。设为 0 表示无限制。",
        "history_limit_items": "条",
        "language_title": "语言",
        "language_desc": "选择应用的显示语言。",
        "launch_at_login_title": "开机自启",
        "launch_at_login_desc": "登录 Mac 时自动启动剪贴板。",
        "launch_at_login_toggle": "开机自启",
        "login_approval_required": "请在系统设置中允许 Pastes 登录时运行，以完成自启动设置。",
        "login_open_settings": "打开登录项设置",
        "login_change_failed": "无法更改登录项：",
        "accessibility_title": "自动粘贴权限",
        "accessibility_enabled": "系统键盘控制权限已开启，可以自动粘贴。",
        "accessibility_required": "自动粘贴需要系统键盘控制权限，复制历史内容仍可使用。",
        "accessibility_open_settings": "打开权限设置",
        "paste_permission_required": "已复制，可用 ⌘V 粘贴。自动粘贴需要系统键盘控制权限。",
        "paste_permission_settings": "权限设置",
        "update_title": "更新",
        "update_desc": "检查 Pastes 的新版本。",
        "update_development_desc": "开发版已禁用自动更新。",
        "update_start_failed": "无法启动更新服务：",
        "clipboard_error_title": "无法复制剪贴板内容",
        "storage_error_title": "剪贴板存储出错",
        "storage_open_error": "无法打开剪贴板历史，已有文件已保留。",
        "check_update_now": "检查更新",
        "version_label": "版本",
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
