# 语音电脑助手

## 为什么开发

遥控器的语音键已经能把声音送进 Mac 的虚拟声卡，但「说一句话」和「电脑真的去做」之间还缺一层：谁来理解这句话、谁来动手。本功能把这条链路补全：语音仍交给用户自己的输入法转字，字进入一个已配对的 Agent 应用（Claude Code 等），由 Agent 通过本机 MCP 工具操作这台 Mac。

它不是一个内置的大模型助手，也不替代系统听写。它把「AI 能操作电脑」变成可授权、可撤销、可审计、逐层放行的本机能力。

## 用户功能

- 新增设置页「语音电脑助手」，默认关闭。
- 分级授权：只读工具自动执行；启动应用/打开文件需确认；输入注入（输入文字、点击、快捷键、剪贴板）需确认；AppleScript 默认拒绝。每一层可单独设为「自动 / 每次确认 / 拒绝」。
- 可以在确认弹窗里选择「始终允许」，授权按「工具 + 前台应用」记忆，可一键全部清除；收紧策略时自动清掉该层级的记忆授权。
- 配对制客户端：新建配对后一次性展示令牌和一行 `claude mcp add-json` 命令，令牌只保存 SHA-256 哈希，可单独撤销或删除。
- 说完自动提交：语音结束时自动切到目标 Agent 应用并按下回车，等待时间可调（默认 1 秒）。默认关闭。
- 审计日志：记录时间、客户端、工具、层级、参数摘要（文字类只记长度）、耗时和结果，可在页面查看与清空。

## 范围与非目标

本次只做本机 `stdio` MCP 控制，不开放 HTTP/TCP 端口，不做远程控制，不做云端转发，不做屏幕截图或录屏，不读取第三方 App 的私有数据，不提供 shell。语音转文字仍由用户自己的输入法负责，App 不做识别也不保存音频。

所有操作都在 App 进程内执行，因为辅助功能与输入监控权限属于 App，而不是 Helper。

## 关键设计与开发过程

- 安全边界：MCP Helper 是独立进程、没有 TCC 权限；它只做 stdio ↔ Unix 域套接字的桥，真正的执行全部回到 App 主进程。套接字位于 `Application Support/RemoteMic/Control/v1/bridge.sock`，目录 `0700`、套接字与授权文件 `0600`。
- 每次调用都重新校验令牌和撤销状态；授权文件只存哈希。请求超时（默认 20 秒）视为拒绝，避免弹窗堆积；同时只允许一个确认弹窗，第二个请求直接拒绝。
- 审计摘要对 `text`、`script` 参数只记录长度，不落原文，避免把用户口述内容写进日志。
- `ControlPolicy.decision(for:bundleIdentifier:)` 是唯一的判定入口：功能开关 → 前台应用存在性 → 层级决策 → 记忆授权。收紧策略时按层级清理记忆授权，避免权限比用户以为的更宽。
- 语音提交只做最后一公里：激活目标 App、等待输入法把文字落进输入框、再发回车。目标 App 未运行时不盲发按键，只记录日志。
- 工具全部实现于 `ComputerControlExecutor`，使用 Accessibility（AXUIElement）与 CGEvent；坐标类工具使用左上原点。

## 涉及文件

- `Package.swift`：新增 `SayAllControlKit`、`SayAllControl` 目标，App 与测试目标声明依赖。
- `Sources/SayAllControlKit/`：工具目录与 JSON Schema、分级策略、审计日志、令牌授权、桥协议（UDS 客户端/编解码）、MCP stdio 服务端。
- `Sources/SayAllControl/main.swift`：Helper 入口，只接受 `serve`。
- `Sources/RemoteMic/ComputerControlService.swift`：App 内控制桥（UDS 监听、鉴权、策略、审批、执行、审计）。
- `Sources/RemoteMic/ComputerControlExecutor.swift`：14 个工具的实现。
- `Sources/RemoteMic/ComputerControlApprovalCenter.swift`：确认弹窗（一次性令牌、倒计时、三种选择）。
- `Sources/RemoteMic/ComputerControlSettingsView.swift`：设置页。
- `Sources/RemoteMic/VoiceAgentSubmitter.swift`：语音结束 → 切 App → 回车。
- `Sources/RemoteMic/SettingsView.swift`、`BridgeAppModel.swift`、`RemoteMicApp.swift`：侧栏入口、语音结束挂钩、启动初始化。
- `scripts/build-app.sh`：把 `SayAllControl` 打进 `Contents/Helpers/`。
- `Tests/RemoteMicTests/ComputerControlPolicyTests.swift`：9 项策略与审计单测。

## 待验证

- 真机遥控器 + 豆包输入法 + Claude Code 的完整语音闭环（需要真实硬件和已登录客户端）。
- UI 截图（中文浅色/深色、默认与最小窗口）。
- AppleScript 工具在真实脚本下的超时与回滚行为。
