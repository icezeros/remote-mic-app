import Foundation

/// Risk tier of a computer-control tool. Higher tiers require stronger user intent.
public enum ControlTier: Int, Codable, CaseIterable, Comparable, Sendable {
    /// Observational only. Never mutates the machine.
    case read = 0
    /// Launches or focuses apps, opens URLs/files, changes window geometry.
    case launch = 1
    /// Injects input events or mutates user-visible state (typing, clicking, clipboard).
    case input = 2
    /// Arbitrary script execution and other escapes. Denied unless explicitly enabled.
    case privileged = 3

    public static func < (lhs: ControlTier, rhs: ControlTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var localizedName: String {
        switch self {
        case .read: return "只读"
        case .launch: return "启动/窗口"
        case .input: return "输入注入"
        case .privileged: return "脚本执行"
        }
    }
}

/// Stable identifier for every tool the control bridge exposes.
public enum ControlToolID: String, CaseIterable, Sendable {
    case listRunningApps = "list_running_apps"
    case getFrontmostApp = "get_frontmost_app"
    case getUiTree = "get_ui_tree"
    case activateApp = "activate_app"
    case openUrl = "open_url"
    case openPath = "open_path"
    case setWindowFrame = "set_window_frame"
    case typeText = "type_text"
    case pressKey = "press_key"
    case click = "click"
    case scroll = "scroll"
    case getClipboard = "get_clipboard"
    case setClipboard = "set_clipboard"
    case runAppleScript = "run_applescript"

    public var tier: ControlTier {
        switch self {
        case .listRunningApps, .getFrontmostApp, .getUiTree:
            return .read
        case .activateApp, .openUrl, .openPath, .setWindowFrame:
            return .launch
        case .typeText, .pressKey, .click, .scroll, .getClipboard, .setClipboard:
            return .input
        case .runAppleScript:
            return .privileged
        }
    }

    public var summary: String {
        switch self {
        case .listRunningApps: return "列出当前运行中的图形应用"
        case .getFrontmostApp: return "读取当前前台应用与窗口标题"
        case .getUiTree: return "读取前台窗口的辅助功能元素树"
        case .activateApp: return "切换到（或启动）指定应用"
        case .openUrl: return "用默认浏览器打开 URL"
        case .openPath: return "打开文件或文件夹"
        case .setWindowFrame: return "移动或缩放前台窗口"
        case .typeText: return "向当前焦点输入文字"
        case .pressKey: return "发送按键或快捷键组合"
        case .click: return "在指定屏幕坐标点击"
        case .scroll: return "滚动前台视图"
        case .getClipboard: return "读取剪贴板文本"
        case .setClipboard: return "写入剪贴板文本"
        case .runAppleScript: return "执行 AppleScript（高风险）"
        }
    }

    /// Tools that only make sense when a foreground app exists.
    public var requiresFrontmostApp: Bool {
        switch self {
        case .getUiTree, .setWindowFrame, .typeText, .pressKey, .click, .scroll:
            return true
        default:
            return false
        }
    }

    /// Arguments that must never be persisted into the audit log verbatim.
    public var redactedArguments: Set<String> {
        switch self {
        case .typeText, .setClipboard, .runAppleScript:
            return ["text", "script"]
        default:
            return []
        }
    }

    public var inputSchemaJSON: String {
        switch self {
        case .listRunningApps, .getFrontmostApp, .getClipboard:
            return #"{"type":"object","properties":{},"additionalProperties":false}"#
        case .getUiTree:
            return #"{"type":"object","properties":{"max_depth":{"type":"integer","minimum":1,"maximum":8,"default":3}},"additionalProperties":false}"#
        case .activateApp:
            return #"{"type":"object","properties":{"bundle_id":{"type":"string"},"name":{"type":"string"}},"anyOf":[{"required":["bundle_id"]},{"required":["name"]}],"additionalProperties":false}"#
        case .openUrl:
            return #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}"#
        case .openPath:
            return #"{"type":"object","properties":{"path":{"type":"string"},"reveal_in_finder":{"type":"boolean","default":false}},"required":["path"],"additionalProperties":false}"#
        case .setWindowFrame:
            return #"{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"additionalProperties":false}"#
        case .typeText:
            return #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
        case .pressKey:
            return #"{"type":"object","properties":{"key":{"type":"string"},"modifiers":{"type":"array","items":{"type":"string","enum":["command","shift","option","control","fn"]}}},"required":["key"],"additionalProperties":false}"#
        case .click:
            return #"{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"button":{"type":"string","enum":["left","right"],"default":"left"},"click_count":{"type":"integer","minimum":1,"maximum":3,"default":1}},"required":["x","y"],"additionalProperties":false}"#
        case .scroll:
            return #"{"type":"object","properties":{"delta_x":{"type":"number","default":0},"delta_y":{"type":"number","default":0}},"additionalProperties":false}"#
        case .setClipboard:
            return #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
        case .runAppleScript:
            return #"{"type":"object","properties":{"script":{"type":"string"},"timeout_seconds":{"type":"number","minimum":1,"maximum":30,"default":10}},"required":["script"],"additionalProperties":false}"#
        }
    }

    public var displayName: String { rawValue }
}

/// Everything an MCP client needs to know about one control tool.
public struct ControlToolDescriptor: Equatable, Sendable {
    public let tool: ControlToolID
    public let tier: ControlTier
    public let summary: String
    public let inputSchemaJSON: String

    public init(tool: ControlToolID) {
        self.tool = tool
        tier = tool.tier
        summary = tool.summary
        inputSchemaJSON = tool.inputSchemaJSON
    }

    public static let all: [ControlToolDescriptor] = ControlToolID.allCases.map(
        ControlToolDescriptor.init(tool:)
    )
}
