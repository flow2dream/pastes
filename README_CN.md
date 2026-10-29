# Pastes

macOS 剪贴板历史管理工具。一键查看、搜索、固定和管理你的剪贴板记录。

[English](README.md)

## 功能特性

- **剪贴板历史** — 自动记录所有复制的文本和图片内容
- **富文本支持** — 保留原文本格式（Word、代码等）
- **全局快捷键** — 默认 `⌘⇧V` 随时唤起，支持自定义
- **一键粘贴** — 点击记录项直接粘贴到当前输入位置
- **固定收藏** — 重要记录置顶固定，不受清理影响
- **搜索过滤** — 快速搜索历史记录
- **记录上限** — 可设置保留的最大条目数，自动清理旧记录
- **开机自启** — 支持登录时自动启动
- **中英双语** — 支持中文和英文界面
- **菜单栏运行** — 常驻菜单栏，不占用 Dock 位置

## 安装

### 方式一：下载 DMG

从 [v1.1.0 Release](https://github.com/flow2dream/pastes/releases/tag/v1.1.0) 下载 `Pastes-1.1.0-arm64.dmg`，打开后将 `Pastes.app` 拖入 Applications 文件夹。安装包适用于 Apple Silicon、macOS 26.0 或更高版本。

> 当前安装包使用开发证书签名，尚未进行 Developer ID 公证。首次安装可能需要在系统设置的「隐私与安全」中明确允许运行。

#### 从旧版升级

v1.1.0 将存储由 SwiftData 改为 SQLite，**旧版历史和固定记录不会自动迁移，升级后新的历史列表会从空记录开始**。旧数据库文件会保留，不会读取或删除；如需保留可直接使用的旧历史，请先备份并保留旧版应用。正式版的新数据位于 `~/Library/Application Support/com.pastes.app.pastes/clipboard.sqlite`。

![Pastes 界面示例](docs/images/pastes-dark.png)

### 方式二：从源码构建

无需安装完整 Xcode。使用 macOS Command Line Tools（Swift 6.2 或更高版本）即可开发：

```bash
# 如果尚未安装命令行工具，执行后按系统提示完成安装
xcode-select --install

git clone https://github.com/flow2dream/pastes.git
cd pastes
make run
```

本机已安装命令行工具时，跳过 `xcode-select --install`。可以用 Cursor、VS Code 或其他编辑器打开项目目录。

- `make build`：编译并打包 Debug 开发版。
- `make run`：编译并打开开发版。
- `make test`：运行全部回归测试。
- `make release`：编译并打包 Release 开发版。
- `make distribution`：生成正式 `build/Distribution/Pastes.app`。
- `make package`：生成正式 DMG 与 `SHA256SUMS`，保存在 `build/releases/v<版本>/`。

首次构建需要联网，由 Swift Package Manager 下载锁定版本的 Sparkle。无需数据库服务、Apple 开发者证书或环境密钥。图标由系统 `iconutil` 生成，应用使用本地 ad hoc 签名。

如果本机已有有效的开发签名证书，可把它的 40 位证书指纹写入项目根目录 `.pastes-signing-identity`，或设置 `PASTES_SIGN_IDENTITY`；环境变量优先。该本地文件已被 Git 忽略，缺省仍为 ad hoc。使用同一证书能保持重编译前后的签名身份一致；自动粘贴仍需系统授予辅助功能权限，设置页会显示应用实际检测到的状态。

默认输出为 `build/Debug/Pastes Dev.app`，开发版快捷键为 **`⌘⌥⇧V`**，与已安装的正式版区分。应用启动后常驻菜单栏，不显示 Dock 图标。自动粘贴功能仍需在「系统设置 → 隐私与安全性 → 辅助功能」中为开发版授权。

开发版使用独立的 bundle ID `com.pastes.app.pastes.dev`，历史保存在 `~/Library/Application Support/com.pastes.app.pastes.dev/clipboard.sqlite`。存储已由 SwiftData 改为系统 SQLite，文字、图片、富文本和固定记录均持久化。**旧版 SwiftData 历史不会自动迁移，旧文件不会被读取或删除。** 开发版禁用自动更新，避免被现有正式版更新源覆盖。

完整 Xcode 仍可作为可选编辑器。现有 `.xcodeproj` 保留，但上述命令不使用 `xcodebuild` 或 Xcode 预览宏。

### 构建开发版 DMG

```bash
make release

mkdir -p dmg_staging
cp -R "build/Release/Pastes Dev.app" dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "Pastes Dev" -srcfolder dmg_staging -ov -format UDZO Pastes-Dev.dmg

rm -rf dmg_staging
```

生成的 `Pastes-Dev.dmg` 用于本地开发安装，未做 Developer ID 签名和公证。

### 发布前核验正式更新包

对已有的正式版 DMG 和 appcast 做离线核验，不会安装或运行包内应用：

```bash
xcrun swift scripts/validate-update.swift appcast.xml /path/to/Pastes.dmg
```

核验涵盖更新包长度、Ed25519 签名、应用代码签名、bundle ID、最低系统版本及版本元数据。`sparkle:version` 必须等于包内 `CFBundleVersion`（构建号），`sparkle:shortVersionString` 必须等于 `CFBundleShortVersionString`（展示版本）。开发版 DMG 会被拒绝，不能投放到正式更新源。正式版在启动时初始化 Sparkle，开发版保持禁用更新。

## 权限说明

- **系统控制权限** — 用于自动粘贴功能（模拟 Cmd+V）。正式版首次运行时请求授权；开发版缺少权限时仅显示面板提示，由你点击设置按钮后申请，同一进程最多主动申请一次。可在系统设置中手动开启，应用设置页显示实际事件发送权限状态。

系统开关显示已开但仍不能自动粘贴时，先在应用设置中检查实际权限状态。旧 ad hoc 构建的授权可能不适用于当前稳定签名：退出开发版，在系统权限列表中仅移除旧的 `Pastes Dev.app` 条目，再添加当前 `build/Debug/Pastes Dev.app` 并开启，随后重新启动应用。macOS 可能需要本人认证。使用时先点击目标输入框，再用快捷键唤出历史面板；未授权时内容仍会复制，并显示可手动 `⌘V` 粘贴的提示。

## 使用方式

| 操作 | 说明 |
|------|------|
| `⌘⇧V` | 唤起/隐藏剪贴板面板（全局快捷键） |
| 点击记录项 | 复制并粘贴到当前输入位置 |
| 点击图钉图标 | 固定/取消固定记录 |
| 点击 × 图标 | 删除记录 |
| 左键点击菜单栏图标 | 唤起面板 |
| 右键点击菜单栏图标 | 打开设置 / 退出 |

## 系统要求

- macOS 26.0 或更高版本
- 源码开发：Swift 6.2 或更高版本的 Command Line Tools、首次构建时联网

## 许可证

MIT License
