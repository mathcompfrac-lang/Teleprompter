# 悬浮提词器 - 运行指南

## 第一步：配置开发团队（Xcode 内操作）

1. **Xcode 已打开项目**，你看到的应该是一个 iOS 项目
2. 点击左侧导航栏最顶层的 **Teleprompter** 项目图标
3. 在中间面板选择 **Signing & Capabilities** 标签
4. 在 **Team** 下拉菜单中选择你的 Apple Developer 团队
   - 个人免费账号也可以（会显示 "Your Name (Personal Team)"）
   - 首次使用 Xcode 的话，需要先在 Xcode > Settings > Accounts 登录 Apple ID
5. Xcode 会自动生成 Provisioning Profile

## 第二步：选择运行目标

- **连上真机**：用 iPhone 数据线连电脑，在顶部工具栏的设备菜单中选择你的 iPhone
- **使用模拟器**：在设备菜单中选择一个模拟器（如 iPhone 16 Pro）

## 第三步：运行

按 **Cmd + R** 运行，或者点击顶部的 ▶ 按钮。

## 常见问题

### "Failed to code sign" 错误
- 检查 Signing & Capabilities 中的 Team 是否已选择
- 检查 Apple ID 是否已在 Xcode > Settings > Accounts 中登录

### 模拟器不支持画中画
- 画中画（AVPictureInPicture）在模拟器中**不可用**
- 需要**真机测试**才能看到浮动窗口效果
- 模拟器上仍可测试：脚本管理、设置页面、试用逻辑等

### 麦克风权限
- 首次使用语音模式时会弹出权限申请
- 如果在模拟器上测试语音功能：系统偏好设置 > 安全性与隐私 > 麦克风 > 勾选 Xcode

## 核心文件索引

| 文件 | 用途 |
|------|------|
| `Teleprompter/App/ContentView.swift` | 主页面（脚本选择 + 控制面板） |
| `Teleprompter/Features/PIP/PIPManager.swift` | 画中画控制器 |
| `Teleprompter/Features/PIP/PIPContentViewController.swift` | 画中画内容渲染 |
| `Teleprompter/Features/Teleprompter/TeleprompterViewModel.swift` | 滚屏核心逻辑 |
| `Teleprompter/Features/Teleprompter/TeleprompterControlView.swift` | 控制面板 UI |
| `Teleprompter/Features/Audio/SpeechDetector.swift` | 语音检测 |
| `Teleprompter/Features/ScriptEditor/ScriptListView.swift` | 脚本列表 |
| `Teleprompter/Features/ScriptEditor/ScriptEditorView.swift` | 脚本编辑器 |
| `Teleprompter/Features/Settings/SettingsView.swift` | 设置页面 |
| `Teleprompter/Features/Usage/UsageTracker.swift` | 7 次试用 |

## 后续开发

需要继续时跟我说：
- **加登录**：Firebase 手机号登录
- **加付费**：StoreKit 2 订阅 + 按次付费
- **加云同步**：Firebase Firestore 同步脚本
- **优化 UI**：精细调整界面
- **提交 App Store**：配置证书、截图、描述
