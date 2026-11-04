# Pastes 1.2.0

Pastes 1.2.0 将剪贴板历史、图片架、截图标注与悬浮参考整合到同一个菜单栏工具中。

## 新功能

- **图片架**：通过可自定义快捷键显示／收起，收集复制的图片、导入的图片和录屏，也可被动监听系统截图目录。悬停预览、金色固定标识、左右批量移除和撤销、拖出副本，以及自适应或指定数量的保留设置。
- **内置截图与标注**：框选后移动或调整选区，使用矩形、椭圆、箭头、画笔、文字和颜色工具；确认后选择「复制并挂上」「另存」或「固定到屏幕」。另存只保存文件，固定暂不入架。
- **悬浮参考图片**：任意位置拖动，单击选中后用系统双指捏合／张开缩放，并显示缩放百分比。右键可编辑、复制、关闭挂回图片架，或销毁丢弃。
- **图片与录屏编辑**：图片编辑支持另存副本或覆盖媒体库中的当前图片；录屏支持缩略图、播放及 AVKit 裁剪。外部导入源文件不被覆盖。
- **来源动画**：截图确认、悬浮图关闭挂回及从架上取下时显示衔接动画；外部复制无法读取图片边界时使用淡入。遵循系统「减少动态效果」设置。

## 界面与修复

- 剪贴板、设置、图片架与截图工具栏采用统一玻璃卡片、细高光和浅／深色外观。设置窗口去掉重复系统标题栏，保留标题区拖动、小关闭按钮及 ⌘W。
- 三个全局快捷键均可自定义，支持功能键；录入期间暂停已有快捷键，冲突时保留旧绑定。
- 修复隐藏应用后唤出图片架同时恢复旧设置窗口的问题，以及剪贴板面板打开时截图确认的入架动画问题。
- 改善切换软件／桌面时的浮层收起、图片架空白区域收起、悬停预览命中及悬浮图反复取下／挂回的状态处理。
- 移除系统截图接管与另存入架开关。旧版遗留的接管配置仅在仍属于本应用时恢复，不覆盖用户或其他应用的修改。

## 安装与使用

- 下载 `Pastes-1.2.0-arm64.dmg`，将 `Pastes.app` 拖入 Applications。
- 要求 **Apple Silicon、macOS 26.0 或更高版本**。安装包使用开发证书签名，**尚未进行 Developer ID 公证**；首次打开可能需要在系统设置的「隐私与安全性」中明确允许。
- 正式版默认快捷键：剪贴板 **⌘⇧V**、图片架 **⌃⌥T**、截图 **⌃⌥S**。图片架默认关闭，需要先在设置中启用；鼠标停在屏幕顶部不会唤出。
- 自动粘贴需系统控制权限；截图首次使用需屏幕录制权限。未授予自动粘贴权限时仍可复制后手动 ⌘V。
- 随附 `SHA256SUMS`，可在下载目录执行 `shasum -a 256 --check SHA256SUMS` 验证文件。

## 数据与升级

- 从 **1.1.0** 升级继续使用同一 SQLite 数据库，不会重置现有历史和固定记录。
- 从 **1.0.x 或更早版本** 升级时，旧 SwiftData 历史不会自动迁移；旧文件仍保留。需要旧记录时请先备份并保留旧版应用。
- 开发版与正式版使用独立应用身份和数据目录；本次发布不会安装或替换本机已运行的应用。
- 移除架上条目不会删除外部源文件；媒体库隐藏副本可撤销，手动清理后不能再撤销。悬浮参考不会跨应用退出保存窗口位置。

## 验证与已知范围

本版构建号为 **5**。发布前运行 199 项自动测试，并独立验证窗口协调、图片架快捷键与收起、截图／悬浮图挂回及取下动画。正式 DMG 的镜像完整性、代码签名、版本、架构、SHA-256 及更新源的 Ed25519 签名均已核验。

外部图片来源动画依赖对应应用的辅助功能信息，无法保证所有软件均能提供图片位置。实际重新登录后的自动启动及应用内更新的替换／重启闭环尚未完整实测。

图片架与部分原生交互借鉴 [Tendedero](https://github.com/alejandrobujan/tendedero)，使用遵循 MIT 许可；归属与许可见 [第三方声明](../THIRD_PARTY_NOTICES.md)。

## English

Pastes 1.2.0 adds a shortcut-driven capture shelf, built-in region screenshots and annotation, floating reference images with native pinch zoom, image save-copy/overwrite, and movie playback/trimming. Clipboard history, settings and capture tools share a frosted-glass interface.

Save writes a file only. Pin keeps a screenshot floating until you choose Close to return it to the shelf, or Destroy to discard it. The shelf opens with its shortcut rather than a top-edge hover. All three shortcuts are configurable.

Requires Apple Silicon and macOS 26+. The package is development-certificate signed and is not notarized. Existing 1.1.0 SQLite history is preserved; older SwiftData history is not automatically migrated. See the [English README](../README.md) for installation, permissions, data locations and usage.
