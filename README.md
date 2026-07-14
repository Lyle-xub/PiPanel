<div align="center">
  <img src="docs/assets/icon-256.png" width="112" height="112" alt="PiPanel icon">

  # PiPanel

  **把正在运行的真实 macOS 窗口，变成可直接操作的画中画。**

  不是截图，也不只是镜像。你可以直接在画中画里点击、滚动和输入，操作会实时作用于原窗口。

  [![GitHub Stars](https://img.shields.io/github/stars/Lyle-xub/PiPanel?style=flat-square&logo=github&label=Stars)](https://github.com/Lyle-xub/PiPanel/stargazers)
  [![Latest Release](https://img.shields.io/github/v/release/Lyle-xub/PiPanel?style=flat-square&label=Release)](https://github.com/Lyle-xub/PiPanel/releases/latest)
  [![Downloads](https://img.shields.io/github/downloads/Lyle-xub/PiPanel/total?style=flat-square&label=Downloads)](https://github.com/Lyle-xub/PiPanel/releases)
  ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple)

  [官网](https://pipanel.app) · [下载发行版](https://github.com/Lyle-xub/PiPanel/releases) · [提交问题](https://github.com/Lyle-xub/PiPanel/issues)
</div>

---

## PiPanel 有什么不同

普通画中画通常只支持视频，普通窗口镜像通常只能看、不能操作。PiPanel 会把选中的真实窗口移动到一个私有虚拟显示器上，让窗口继续正常运行，再通过 ScreenCaptureKit 将它显示为跨桌面、始终置顶的悬浮画中画。

鼠标与键盘操作会经过坐标转换和辅助功能接口转发回源窗口，所以画中画不只是预览，而是一个真正可以继续使用的窗口入口。

```mermaid
flowchart LR
    A["正在运行的源窗口"] --> B["私有虚拟显示器"]
    B --> C["ScreenCaptureKit 实时捕获"]
    C --> D["置顶画中画面板"]
    D -->|"点击、滚动、键盘输入"| E["交互与坐标转换"]
    E --> A
```

## 开源版功能

- 将任意普通应用窗口变成实时画中画
- 在画中画中直接点击、滚动、拖拽和键盘输入
- 把窗口甩向屏幕边缘，快速触发画中画
- 从菜单栏按应用和窗口标题精确选择
- 同时开启多个画中画，并按指定角落自动排列
- 跨 Space 显示，并可覆盖全屏应用
- 拖动边缘调整画中画尺寸，源窗口同步适配
- 激活源应用时自动恢复真实窗口并隐藏画中画
- 操作完成后自动把键盘焦点归还给之前的应用
- 自定义帧率、默认宽度、堆叠角落、圆角和阴影
- 开机启动、权限引导和活跃会话管理
- 所有窗口画面和交互均在本机处理

## 系统要求

- macOS 14 Sonoma 或更高版本
- Apple Silicon Mac（M 系列芯片）
- Xcode 15 或更高版本（从源码构建）
- 屏幕录制权限
- 辅助功能权限

> PiPanel 使用非公开的 `CGVirtualDisplay` API 创建虚拟显示器，因此不适合通过 Mac App Store 分发。系统升级也可能影响相关行为。

## 安装

### 下载发行版

前往 [GitHub Releases](https://github.com/Lyle-xub/PiPanel/releases) 下载最新版本。

首次运行时，PiPanel 会引导你开启：

1. **屏幕录制**：捕获选中窗口的实时画面。
2. **辅助功能**：移动和调整源窗口，并转发鼠标与键盘操作。

### 从源码构建

```bash
git clone https://github.com/Lyle-xub/PiPanel.git
cd PiPanel
open PiPanel.xcodeproj
```

在 Xcode 中：

1. 选择 `PiPanel` target。
2. 在 Signing & Capabilities 中选择自己的开发团队。
3. 选择 **My Mac**，然后运行。

仓库也保留了 XcodeGen 配置。如需重新生成工程：

```bash
brew install xcodegen
xcodegen generate
```

## 使用方法

1. 启动 PiPanel，并授予屏幕录制和辅助功能权限。
2. 点击菜单栏中的 PiPanel 图标，从窗口列表中选择一个窗口。
3. 移动画中画、拖动边缘调整大小，或直接在其中点击和输入。
4. 也可以把真实窗口快速甩向屏幕边缘，直接创建画中画。
5. 在菜单栏的活跃会话列表中关闭单个或全部画中画。

## 项目结构

```text
PiPanel/
├── App/             App 生命周期与配置
├── Capture/         虚拟显示器、窗口枚举与 ScreenCaptureKit
├── Interaction/     坐标转换、鼠标和键盘事件转发
├── MenuBar/         菜单栏窗口选择与会话管理
├── PiPPanel/        悬浮面板、渲染、缩放和关闭交互
├── Permissions/     屏幕录制与辅助功能权限
├── Settings/        通用、外观与开机启动设置
└── Welcome/         首次启动引导
```

关键实现入口：

- `Capture/CaptureSession.swift`：管理源窗口、虚拟显示器和实时捕获。
- `Capture/VirtualDisplayHost.swift`：创建与销毁私有虚拟显示器。
- `Interaction/InteractionForwarder.swift`：把画中画交互转发至源窗口。
- `PiPPanel/PiPSessionManager.swift`：管理画中画会话生命周期。
- `PiPPanel/PiPVideoLayerView.swift`：显示捕获画面并处理移动、缩放等手势。

## 开源版与官方发行版

本仓库提供 PiPanel 的开源核心实现，可用于学习、研究、构建和贡献。官网提供的官方发行版可能额外包含许可证、设备管理和专业版功能，因此界面与功能范围可能与本仓库直接构建的版本不同。

如果问题只出现在官方发行版中，请在 Issue 中注明版本号、macOS 版本和设备型号。

## 已知限制

- DRM 或受系统保护的窗口可能无法捕获。
- 某些系统窗口、弹出层和非标准窗口不一定会出现在窗口列表中。
- 应用退出、窗口关闭或源窗口结构发生重大变化时，对应画中画会自动结束。
- 虚拟显示器依赖 macOS 非公开接口，未来系统版本可能需要适配。

## 贡献

欢迎提交 Issue 和 Pull Request。提交代码前建议：

1. 先搜索是否已有相同问题。
2. 尽量附上复现步骤、macOS 版本、Mac 型号和相关日志。
3. 保持修改范围聚焦，并为坐标转换等纯逻辑代码补充测试。
4. 确认项目可以在当前最低支持版本上构建。

## 隐私

窗口捕获、画面渲染和交互转发均在本机完成。开源核心版本不包含分析、广告或遥测 SDK。详细说明见 [隐私政策](https://pipanel.app/privacy.html)。

## Star 增长

如果 PiPanel 对你有帮助，欢迎点一个 Star。你的支持会帮助更多人发现这个项目。

[![PiPanel Star History](https://api.star-history.com/svg?repos=Lyle-xub/PiPanel&type=Date)](https://www.star-history.com/#Lyle-xub/PiPanel&Date)

## 许可证

本仓库目前尚未附带开源许可证。在正式添加 `LICENSE` 文件前，请勿假定代码可以被自由复制、重新分发或用于商业产品。如有相关需求，请先联系项目维护者。
