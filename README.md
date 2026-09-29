# OpenLaunchpad

使用 Swift / AppKit 编写的原生 macOS 全屏应用启动台，可修改源码，自定义外观与交互。

![应用图标](docs/AppIcon.png)

## 功能

- 扫描应用程序目录，搜索并启动应用。
- 全屏分页、键盘翻页、应用内双指横向滑动。
- 拖动排序、边缘停留翻页、悬停创建文件夹、文件夹重命名与解散。
- 长按或按 Option 进入编辑模式；支持将带 App Store 收据的应用移到废纸篓。
- 壁纸模糊、暗色覆盖、行列数、可选热角。
- 菜单栏入口、Control + Option + L 快捷键与登录后台启动。
- 本地 JSON 布局保存，应用目录变化后刷新。

本项目为独立实现，与 Apple 或 BuhoLaunchpad 无隶属关系。

## 下载与使用

在 [Releases](https://github.com/Ayang0097/OpenLaunchpad/releases) 下载 ZIP，解压后将 OpenLaunchpad.app 拖到“应用程序”文件夹，再打开。

当前安装包要求 **Apple Silicon（arm64）、macOS 14 或以上**。安装包使用本地 ad-hoc 签名，未经过 Apple 公证；系统可能阻止首次打开。信任本项目后，可按照 macOS“隐私与安全性”中的提示允许打开。

直接拖入应用程序文件夹不会自动设置登录启动。需要登录后台启动时，可从源码运行下面的安装脚本。

## 从源码构建

需要 Xcode Command Line Tools（Swift、iconutil、codesign）以及运行迁移/测试脚本所需的 Python 3。

```sh
git clone https://github.com/Ayang0097/OpenLaunchpad.git
cd OpenLaunchpad
./build.sh
open dist/OpenLaunchpad.app
```

安装或更新到 /Applications，并添加登录后台启动：

```sh
./install.sh
```

图标由 make_icon.swift 生成；修改后再次构建会自动更新图标资源。

## 操作

输入名称后按 Return 启动首个匹配结果；点击分页圆点、双指横向滑动或按 Command + 左右方向键翻页。拖动图标调整顺序，在目标图标中央停留约 0.6 秒后可建立文件夹；边缘停留约 0.55 秒翻页。点击文件夹标题可重命名，右键菜单可解散文件夹。

Escape 会按当前状态取消拖动、退出编辑、清空搜索、关闭文件夹或隐藏启动台。搜索框右侧更多按钮可打开设置。

## 数据与可选迁移

布局保存在：

```text
~/Library/Application Support/OpenLaunchpad/layout.json
```

该文件属于用户数据，不随仓库发布。备份此文件即可保存个人排列。

如本机存在 BuhoLaunchpad 的布局数据库，可在首次使用前执行：

```sh
python3 migrate_buho_layout.py
```

迁移只读原数据库；目标布局已存在时会停止。该脚本依赖第三方数据库结构，不能保证适配所有版本。restore_original.sh 仅在 BuhoLaunchpad 仍安装时停用 OpenLaunchpad 的登录启动并打开原应用。

## 验证与已知边界

```sh
python3 Tests/layout_regression.py
zsh -n build.sh install.sh restore_original.sh
./build.sh
```

布局回归检查覆盖页面溢出、顺序、重复应用、空/单项文件夹和空布局。它不能替代真实触控板手感验证。

- 暂不支持系统级捏合唤出、文件夹整体拖动和 Intel 安装包。
- 背景来自模糊后的系统壁纸，不是实时模糊其他窗口。
- 应用扫描在主线程执行；临时不可访问的应用重新出现后，位置可能变化。
- 减少动态效果偏好尚未完整覆盖，保存失败目前记录日志。
- 本项目处于早期迭代阶段，重要布局建议定期备份。
