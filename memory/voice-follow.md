# Teleprompter 开发记录

## 2026-05-04 语音跟随功能修复

### 已完成功能

#### 主App语音识别跟随
- **实现方式**：基于 SFSpeechRecognizer 实时识别 + 增量匹配
- **匹配策略**：`fastMatch` 从当前位置往后连续匹配，优先快速响应
- **能量辅助**：检测到说话但识别结果未跟上时小幅推进
- **匹配间隔检测**：超过0.5秒没匹配成功则加速推进
- **效果**：高亮基本跟上真实朗读速度

#### 悬浮窗语音跟随
- **实现方式**：独立计算，接收主App的 `charIndex` 和 `scrollProgress`
- **定位策略**：`scrollToCharIndex()` 使用 TextKit 精确计算字符Y坐标
- **显示效果**：正在阅读的文字保持在悬浮窗中央位置
- **高亮同步**：同时更新高亮进度

### 待解决问题

#### 悬浮窗透明度无效
- **现象**：悬浮窗启动时有半透明效果闪现，之后变成黑色不透明
- **尝试方案**：
  1. `view.backgroundColor` - 被系统覆盖
  2. `backgroundView` 子视图 - 被系统覆盖
  3. `CALayer` 背景层 - 仍然被覆盖
- **推测原因**：`AVPictureInPictureVideoCallViewController` 在 PIP 启动后会重新配置 view 层级，覆盖背景设置

### 关键代码位置

- **ViewModel**: `TeleprompterViewModel.swift`
  - `setupSpeechDetection()`: 语音识别回调
  - `fastMatch()`: 快速匹配算法
  - `tickDisplayLink()`: 能量辅助推进
  - `updateScrollFromCharIndex()`: 同步到PIP

- **PIP内容**: `PIPContentViewController.swift`
  - `scrollToCharIndex()`: 让阅读位置保持在中央
  - `applyAttributedText()`: 高亮渲染

- **PIP管理**: `PIPManager.swift`
  - `setCharIndex()`: 传递字符索引到悬浮窗
  - `setScrollProgress()`: 传递进度比例

### 高亮保留行数
- 主App预览：保留4行高亮在屏幕中
- 悬浮窗：让阅读位置保持在窗口中央
