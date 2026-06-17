# Pastes

macOS 剪贴板历史管理工具。一键查看、搜索、固定和管理你的剪贴板记录。

## 功能特性

- **剪贴板历史** — 自动记录所有复制的文本内容
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

从 [Releases](../../releases) 页面下载最新版本的 `Pastes.dmg`，打开后将 Pastes 拖入 Applications 文件夹。

> 首次打开时，macOS 可能提示"无法验证开发者"。右键点击 app → 选择「打开」即可。

### 方式二：从源码构建

```bash
git clone https://github.com/yourusername/pastes.git
cd pastes
open pastes.xcodeproj
```

在 Xcode 中 `⌘R` 运行。

### 构建 DMG 安装包

```bash
# 编译 Release 版本
xcodebuild -project pastes.xcodeproj -scheme pastes -configuration Release -derivedDataPath build clean build

# 创建 DMG
mkdir -p dmg_staging
cp -R build/Build/Products/Release/pastes.app dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "Pastes" -srcfolder dmg_staging -ov -format UDZO Pastes.dmg

# 清理
rm -rf dmg_staging build
```

生成的 `Pastes.dmg` 即为可分发的安装包。

## 权限说明

- **辅助功能权限** — 用于自动粘贴功能（模拟 Cmd+V）。首次运行时会弹出授权请求，或在「系统设置 → 隐私与安全性 → 辅助功能」中手动开启。

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

## 许可证

MIT License
