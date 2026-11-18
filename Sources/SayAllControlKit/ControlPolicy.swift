import Foundation

/// How the app treats one tool invocation after policy evaluation.
public enum ControlDecision: String, Codable, CaseIterable, Sendable {
    /// Execute immediately without interrupting the voice session.
    case allow
    /// Ask the user first; remember the answer when they choose to.
    case confirm
    /// Refuse outright. Never offered as a rememberable choice.
    case deny
}

/// Persisted, user-editable policy for the computer-control bridge.
///
/// Defaults follow the product rule: observation is free, launching asks once per
/// app, injection asks every time unless remembered, and script execution stays
/// closed until the user opens it deliberately.
public struct ControlPolicy: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var tierDecisions: [String: ControlDecision]
    /// Tools that are allowed to run without a foreground app.
    public var allowBackgroundInjection: Bool
    /// Remembered approvals, keyed by "<tool>|<bundle id or *>".
    public var rememberedGrants: [String: Date]
    public var approvalTimeoutSeconds: Double

    public static let defaultApprovalTimeout: Double = 20

    public init(
        isEnabled: Bool = false,
        tierDecisions: [String: ControlDecision] = ControlPolicy.defaultTierDecisions,
        allowBackgroundInjection: Bool = false,
        rememberedGrants: [String: Date] = [:],
        approvalTimeoutSeconds: Double = ControlPolicy.defaultApprovalTimeout
    ) {
        self.isEnabled = isEnabled
        self.tierDecisions = tierDecisions
        self.allowBackgroundInjection = allowBackgroundInjection
        self.rememberedGrants = rememberedGrants
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
    }

    public static var defaultTierDecisions: [String: ControlDecision] {
        [
            ControlTier.read.rawValue.description: .allow,
            ControlTier.launch.rawValue.description: .confirm,
            ControlTier.input.rawValue.description: .confirm,
            ControlTier.privileged.rawValue.description: .deny,
        ]
    }

    public func decision(forTier tier: ControlTier) -> ControlDecision {
        tierDecisions[tier.rawValue.description] ?? .deny
    }

    public mutating func setDecision(_ decision: ControlDecision, forTier tier: ControlTier) {
        tierDecisions[tier.rawValue.description] = decision
    }

    public func grantKey(tool: ControlToolID, bundleIdentifier: String?) -> String {
        "\(tool.rawValue)|\(bundleIdentifier ?? "*")"
    }

    /// Full evaluation for one call. `bundleIdentifier` is the frontmost app at
    /// the moment the request arrives, which is what the user actually sees.
    public func decision(
        for tool: ControlToolID,
        bundleIdentifier: String?
    ) -> ControlDecision {
        guard isEnabled else { return .deny }
        if tool.requiresFrontmostApp,
           bundleIdentifier == nil,
           !allowBackgroundInjection {
            return .deny
        }
        let base = decision(forTier: tool.tier)
        if base == .deny { return .deny }
        if base == .confirm,
           rememberedGrants[grantKey(tool: tool, bundleIdentifier: bundleIdentifier)] != nil
            || rememberedGrants[grantKey(tool: tool, bundleIdentifier: nil)] != nil {
            return .allow
        }
        return base
    }

    public mutating func remember(
        _ tool: ControlToolID,
        bundleIdentifier: String?,
        at date: Date = Date()
    ) {
        rememberedGrants[grantKey(tool: tool, bundleIdentifier: bundleIdentifier)] = date
    }

    public mutating func forgetAllGrants() {
        rememberedGrants.removeAll()
    }

    /// Grants are tied to the app they were approved for. Clearing them when the
    /// policy tightens avoids silently keeping a broader permission than intended.
    public mutating func pruneGrants(whenTighteningTo tier: ControlTier, decision: ControlDecision) {
        guard decision != .confirm else { return }
        let prefix = ControlToolID.allCases
            .filter { $0.tier == tier }
            .map { $0.rawValue + "|" }
        rememberedGrants = rememberedGrants.filter { key, _ in
            !prefix.contains(where: { key.hasPrefix($0) })
        }
    }
}

/// A short, human-readable rendering of a tool call for the approval panel and log.
public struct ControlActionSummary: Equatable, Sendable {
    public let tool: ControlToolID
    public let detail: String

    public init(tool: ControlToolID, detail: String) {
        self.tool = tool
        self.detail = detail
    }

    public static func make(
        tool: ControlToolID,
        arguments: [String: any Sendable]
    ) -> ControlActionSummary {
        switch tool {
        case .typeText:
            let text = arguments["text"] as? String ?? ""
            return .init(tool: tool, detail: "输入 \(text.count) 个字符")
        case .pressKey:
            let key = arguments["key"] as? String ?? ""
            let modifiers = (arguments["modifiers"] as? [String] ?? []).joined(separator: "+")
            return .init(tool: tool, detail: modifiers.isEmpty ? key : "\(modifiers)+\(key)")
        case .click:
            let x = (arguments["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (arguments["y"] as? NSNumber)?.doubleValue ?? 0
            return .init(tool: tool, detail: String(format: "(%.0f, %.0f)", x, y))
        case .activateApp:
            let name = arguments["name"] as? String
                ?? arguments["bundle_id"] as? String
                ?? "未知应用"
            return .init(tool: tool, detail: name)
        case .openUrl:
            return .init(tool: tool, detail: arguments["url"] as? String ?? "")
        case .openPath:
            return .init(tool: tool, detail: arguments["path"] as? String ?? "")
        case .setClipboard:
            let text = arguments["text"] as? String ?? ""
            return .init(tool: tool, detail: "写入 \(text.count) 个字符")
        case .runAppleScript:
            let script = arguments["script"] as? String ?? ""
            return .init(tool: tool, detail: "\(script.count) 个字符的脚本")
        case .scroll:
            let dy = (arguments["delta_y"] as? NSNumber)?.doubleValue ?? 0
            return .init(tool: tool, detail: String(format: "dy=%.0f", dy))
        case .setWindowFrame:
            let w = (arguments["width"] as? NSNumber)?.doubleValue
            let h = (arguments["height"] as? NSNumber)?.doubleValue
            if let w, let h {
                return .init(tool: tool, detail: String(format: "%.0f×%.0f", w, h))
            }
            return .init(tool: tool, detail: "调整窗口位置")
        case .getUiTree:
            return .init(tool: tool, detail: "读取元素树")
        case .listRunningApps, .getFrontmostApp, .getClipboard:
            return .init(tool: tool, detail: "")
        }
    }
}
