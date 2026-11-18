import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import SayAllControlKit

enum ControlExecutionError: Error, Equatable {
    case missingAccessibilityPermission
    case noForegroundApp
    case appNotFound(String)
    case elementUnavailable
    case invalidArguments(String)
    case appleScriptFailed(String)
    case appleScriptTimedOut
    case unsupportedKey(String)

    var code: String {
        switch self {
        case .missingAccessibilityPermission: return "control_accessibility_required"
        case .noForegroundApp: return "control_no_foreground_app"
        case .appNotFound: return "control_app_not_found"
        case .elementUnavailable: return "control_element_unavailable"
        case .invalidArguments: return "control_invalid_arguments"
        case .appleScriptFailed: return "control_applescript_failed"
        case .appleScriptTimedOut: return "control_applescript_timeout"
        case .unsupportedKey: return "control_unsupported_key"
        }
    }

    var message: String {
        switch self {
        case .missingAccessibilityPermission:
            return "SayAll 缺少辅助功能权限，无法操作界面。请在系统设置中授权后重试。"
        case .noForegroundApp:
            return "当前没有前台应用，无法执行该操作。"
        case .appNotFound(let target):
            return "找不到应用：\(target)。"
        case .elementUnavailable:
            return "前台应用没有暴露可操作的窗口或元素。"
        case .invalidArguments(let detail):
            return "参数无效：\(detail)。"
        case .appleScriptFailed(let detail):
            return "AppleScript 执行失败：\(detail)。"
        case .appleScriptTimedOut:
            return "AppleScript 执行超时，已终止。"
        case .unsupportedKey(let key):
            return "不支持的按键：\(key)。"
        }
    }
}

/// Executes computer-control tools. All calls must arrive on the main actor
/// because every implementation touches AppKit, Accessibility or CGEvent.
@MainActor
final class ComputerControlExecutor {
    private let accessibilityCheck: () -> Bool

    init(accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.accessibilityCheck = accessibilityCheck
    }

    private var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func execute(
        tool: ControlToolID,
        arguments: [String: ControlJSONValue]
    ) throws -> ControlJSONValue {
        switch tool {
        case .listRunningApps:
            return try listRunningApps()
        case .getFrontmostApp:
            return try describeFrontmostApp()
        case .getUiTree:
            return try uiTree(arguments)
        case .activateApp:
            return try activateApp(arguments)
        case .openUrl:
            return try openURL(arguments)
        case .openPath:
            return try openPath(arguments)
        case .setWindowFrame:
            return try setWindowFrame(arguments)
        case .typeText:
            return try typeText(arguments)
        case .pressKey:
            return try pressKey(arguments)
        case .click:
            return try click(arguments)
        case .scroll:
            return try scroll(arguments)
        case .getClipboard:
            return try readClipboard()
        case .setClipboard:
            return try writeClipboard(arguments)
        case .runAppleScript:
            return try runAppleScript(arguments)
        }
    }

    // MARK: - Observation

    private func listRunningApps() throws -> ControlJSONValue {
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .prefix(40)
            .map { application -> ControlJSONValue in
                .object([
                    "name": .string(application.localizedName ?? ""),
                    "bundle_id": .string(application.bundleIdentifier ?? ""),
                    "pid": .number(Double(application.processIdentifier)),
                    "is_active": .bool(application.isActive),
                    "is_hidden": .bool(application.isHidden),
                ])
            }
        return .object([
            "apps": .array(Array(applications)),
            "message": .string("共 \(applications.count) 个可切换应用。"),
        ])
    }

    private func describeFrontmostApp() throws -> ControlJSONValue {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw ControlExecutionError.noForegroundApp
        }
        let windowTitle = frontmostWindowElement().flatMap { element -> String? in
            attribute(element, kAXTitleAttribute as String) as? String
        }
        return .object([
            "name": .string(application.localizedName ?? ""),
            "bundle_id": .string(application.bundleIdentifier ?? ""),
            "pid": .number(Double(application.processIdentifier)),
            "window_title": .string(windowTitle ?? ""),
            "message": .string(
                windowTitle.map { "\(application.localizedName ?? "") — \($0)" }
                    ?? (application.localizedName ?? "")
            ),
        ])
    }

    private func uiTree(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw ControlExecutionError.noForegroundApp
        }
        let maxDepth = Int(arguments["max_depth"]?.numberValue ?? 3)
            .clamped(to: 1...8)
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var budget = 300
        let tree = describe(element: root, path: [], depth: 0, maxDepth: maxDepth, budget: &budget)
        return .object([
            "app": .string(application.localizedName ?? ""),
            "bundle_id": .string(application.bundleIdentifier ?? ""),
            "max_depth": .number(Double(maxDepth)),
            "nodes": tree,
            "message": .string("已读取 \(budget) 个元素。"),
        ])
    }

    private func describe(
        element: AXUIElement,
        path: [Int],
        depth: Int,
        maxDepth: Int,
        budget: inout Int
    ) -> ControlJSONValue {
        budget -= 1
        var fields: [String: ControlJSONValue] = [
            "path": .array(path.map { .number(Double($0)) }),
        ]
        if let role = attribute(element, kAXRoleAttribute as String) as? String {
            fields["role"] = .string(role)
        }
        if let title = attribute(element, kAXTitleAttribute as String) as? String,
           !title.isEmpty {
            fields["title"] = .string(String(title.prefix(120)))
        }
        if let description = attribute(element, kAXDescriptionAttribute as String) as? String,
           !description.isEmpty {
            fields["description"] = .string(String(description.prefix(120)))
        }
        if let value = attribute(element, kAXValueAttribute as String) as? String,
           !value.isEmpty {
            fields["value"] = .string(String(value.prefix(120)))
        }
        if let placeholder = attribute(element, kAXPlaceholderValueAttribute as String) as? String,
           !placeholder.isEmpty {
            fields["placeholder"] = .string(String(placeholder.prefix(120)))
        }
        if depth >= maxDepth || budget <= 0 {
            return .object(fields)
        }
        let children = (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        if !children.isEmpty {
            var childValues: [ControlJSONValue] = []
            for (index, child) in children.enumerated() where budget > 0 {
                childValues.append(
                    describe(
                        element: child,
                        path: path + [index],
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        budget: &budget
                    )
                )
            }
            fields["children"] = .array(childValues)
        }
        return .object(fields)
    }

    // MARK: - Launch

    private func activateApp(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        let bundleIdentifier = arguments["bundle_id"]?.stringValue
        let name = arguments["name"]?.stringValue
        guard bundleIdentifier != nil || name != nil else {
            throw ControlExecutionError.invalidArguments("需要 bundle_id 或 name")
        }
        let target = resolveApplication(
            bundleIdentifier: bundleIdentifier,
            name: name
        )
        guard let application = target else {
            throw ControlExecutionError.appNotFound(bundleIdentifier ?? name ?? "")
        }
        application.activate(options: [.activateAllWindows])
        return .object([
            "name": .string(application.localizedName ?? ""),
            "bundle_id": .string(application.bundleIdentifier ?? ""),
            "message": .string("已切换到 \(application.localizedName ?? "")。"),
        ])
    }

    private func resolveApplication(
        bundleIdentifier: String?,
        name: String?
    ) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let bundleIdentifier,
           let match = running.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return match
        }
        if let name {
            if let match = running.first(where: {
                ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
            }) {
                return match
            }
            if let match = running.first(where: {
                ($0.localizedName ?? "").lowercased().contains(name.lowercased())
            }) {
                return match
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                try? NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            let searchRoots = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications"),
            ]
            for root in searchRoots {
                let candidate = root.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    try? NSWorkspace.shared.openApplication(
                        at: candidate,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    break
                }
            }
            return nil
        }
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            try? NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        return nil
    }

    private func openURL(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard let raw = arguments["url"]?.stringValue,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file"].contains(scheme)
        else {
            throw ControlExecutionError.invalidArguments("url 必须是 http(s)/mailto/file")
        }
        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw ControlExecutionError.invalidArguments("系统拒绝打开该 URL")
        }
        return .object([
            "url": .string(url.absoluteString),
            "message": .string("已打开 \(url.absoluteString)。"),
        ])
    }

    private func openPath(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            throw ControlExecutionError.invalidArguments("缺少 path")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlExecutionError.invalidArguments("路径不存在：\(expanded)")
        }
        let reveal = arguments["reveal_in_finder"]?.boolValue ?? false
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        return .object([
            "path": .string(expanded),
            "message": .string(reveal ? "已在访达中显示。" : "已打开。"),
        ])
    }

    private func setWindowFrame(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        guard let window = frontmostWindowElement() else {
            throw ControlExecutionError.elementUnavailable
        }
        var applied: [String] = []
        if let x = arguments["x"]?.numberValue, let y = arguments["y"]?.numberValue {
            var point = CGPoint(x: x, y: y)
            if let value = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(window, "AXPosition" as CFString, value)
                applied.append("position")
            }
        }
        if let width = arguments["width"]?.numberValue,
           let height = arguments["height"]?.numberValue {
            var size = CGSize(width: width, height: height)
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, "AXSize" as CFString, value)
                applied.append("size")
            }
        }
        guard !applied.isEmpty else {
            throw ControlExecutionError.invalidArguments("需要 x/y 或 width/height")
        }
        return .object([
            "applied": .array(applied.map { .string($0) }),
            "message": .string("已调整窗口 \(applied.joined(separator: "、"))。"),
        ])
    }

    // MARK: - Input injection

    private func typeText(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            throw ControlExecutionError.invalidArguments("缺少 text")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(maxLength: 20) {
            let units = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return .object([
            "characters": .number(Double(text.count)),
            "message": .string("已输入 \(text.count) 个字符。"),
        ])
    }

    private func pressKey(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        guard let key = arguments["key"]?.stringValue,
              let keyCode = ControlKeyMap.virtualKeyCode(for: key)
        else {
            throw ControlExecutionError.unsupportedKey(arguments["key"]?.stringValue ?? "")
        }
        let modifiers = arguments["modifiers"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw ControlExecutionError.invalidArguments("未知修饰键：\(modifier)")
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw ControlExecutionError.elementUnavailable
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .object([
            "key": .string(key),
            "modifiers": .array(modifiers.map { .string($0) }),
            "message": .string("已发送 \(modifiers.joined(separator: "+"))\(modifiers.isEmpty ? "" : "+")\(key)。"),
        ])
    }

    private func click(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        guard let x = arguments["x"]?.numberValue, let y = arguments["y"]?.numberValue else {
            throw ControlExecutionError.invalidArguments("需要 x 和 y")
        }
        let buttonName = arguments["button"]?.stringValue ?? "left"
        let button: CGMouseButton = buttonName == "right" ? .right : .left
        let count = Int(arguments["click_count"]?.numberValue ?? 1).clamped(to: 1...3)
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .hidSystemState)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button) {
            move.post(tap: .cghidEventTap)
        }
        for clickIndex in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
            else { continue }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return .object([
            "x": .number(x),
            "y": .number(y),
            "message": .string("已点击 (\(Int(x)), \(Int(y)))。"),
        ])
    }

    private func scroll(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard accessibilityCheck() else {
            throw ControlExecutionError.missingAccessibilityPermission
        }
        let deltaX = Int32((arguments["delta_x"]?.numberValue ?? 0).rounded())
        let deltaY = Int32((arguments["delta_y"]?.numberValue ?? 0).rounded())
        guard deltaX != 0 || deltaY != 0 else {
            throw ControlExecutionError.invalidArguments("delta_x 与 delta_y 不能同时为 0")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw ControlExecutionError.elementUnavailable
        }
        event.post(tap: .cghidEventTap)
        return .object(["message": .string("已滚动。")])
    }

    // MARK: - Clipboard

    private func readClipboard() throws -> ControlJSONValue {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return .object([
            "text": .string(text),
            "characters": .number(Double(text.count)),
            "message": .string(text.isEmpty ? "剪贴板没有文本。" : "剪贴板共 \(text.count) 个字符。"),
        ])
    }

    private func writeClipboard(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard let text = arguments["text"]?.stringValue else {
            throw ControlExecutionError.invalidArguments("缺少 text")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .object([
            "characters": .number(Double(text.count)),
            "message": .string("已写入剪贴板。"),
        ])
    }

    // MARK: - AppleScript (privileged)

    private func runAppleScript(_ arguments: [String: ControlJSONValue]) throws -> ControlJSONValue {
        guard let script = arguments["script"]?.stringValue, !script.isEmpty else {
            throw ControlExecutionError.invalidArguments("缺少 script")
        }
        let timeout = (arguments["timeout_seconds"]?.numberValue ?? 10).clamped(to: 1...30)
        let started = Date()
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知错误"
            throw ControlExecutionError.appleScriptFailed(message)
        }
        guard Date().timeIntervalSince(started) <= timeout else {
            throw ControlExecutionError.appleScriptTimedOut
        }
        return .object([
            "result": .string(result?.stringValue ?? ""),
            "message": .string("脚本已执行。"),
        ])
    }

    // MARK: - Accessibility helpers

    private func frontmostWindowElement() -> AXUIElement? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let window = attribute(appElement, kAXFocusedWindowAttribute as String) {
            // AXUIElement is a CF type; downcast via CFGetTypeID to keep Swift happy.
            let value = window as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let windows = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement]
        return windows?.first
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}

enum ControlKeyMap {
    /// Virtual key codes for the keys an agent is likely to need. Names are
    /// case-insensitive and accept the common aliases.
    private static let table: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    static func virtualKeyCode(for name: String) -> CGKeyCode? {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
        if let code = table[normalized] { return code }
        // Single character keys use the ANSI layout position.
        let letters: [Character: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B),
            "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J),
            "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N),
            "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V),
            "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
            "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
            "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
            "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        ]
        guard normalized.count == 1, let character = normalized.first else { return nil }
        return letters[character]
    }
}

private extension String {
    func chunked(maxLength: Int) -> [String] {
        guard maxLength > 0, count > maxLength else { return [self] }
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension ControlJSONValue {
    var arrayValue: [ControlJSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}
