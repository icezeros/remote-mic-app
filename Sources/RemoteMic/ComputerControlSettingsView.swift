import AppKit
import SayAllControlKit
import SwiftUI

/// Settings page for the voice → agent → computer pipeline.
struct ComputerControlSettingsView: View {
    @ObservedObject var service: ComputerControlService
    @ObservedObject private var submitter: VoiceAgentSubmitterProxy

    init(service: ComputerControlService) {
        self.service = service
        _submitter = ObservedObject(wrappedValue: VoiceAgentSubmitterProxy.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语音电脑助手")
                        .font(.system(size: 24, weight: .semibold))
                    Text("说出指令，由 Claude Code 等 Agent 调用本机工具完成操作。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    enablePanel
                    tierPanel
                    pairingPanel
                    voicePanel
                    auditPanel
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isBridgeRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(service.isBridgeRunning ? "控制桥运行中" : "控制桥已停止")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var enablePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "启用语音电脑助手",
                    isOn: Binding(
                        get: { service.policy.isEnabled },
                        set: { newValue in
                            service.updatePolicy { $0.isEnabled = newValue }
                        }
                    )
                )
                .font(.system(size: 14, weight: .medium))
                Text("启用后，已配对的 Agent 才能调用工具。每次操作都会记录审计日志；是否执行由下面的分级授权决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = service.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: AXIsProcessTrusted() ? "checkmark.shield" : "exclamationmark.shield")
                        .foregroundStyle(AXIsProcessTrusted() ? Color.green : Color.orange)
                    Text(AXIsProcessTrusted()
                        ? "辅助功能权限已授予，可以模拟键鼠与读取界面。"
                        : "缺少辅助功能权限：输入、点击、窗口操作会失败。请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 SayAll。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tierPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("分级授权")
                    .font(.system(size: 14, weight: .semibold))
                Text("「自动」直接执行，「确认」每次弹窗（可记住），「拒绝」一律拦截。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ControlTier.allCases, id: \.rawValue) { tier in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.localizedName)
                                .font(.system(size: 13))
                            Text(toolsSummary(for: tier))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { service.policy.decision(forTier: tier) },
                                set: { service.setDecision($0, for: tier) }
                            )
                        ) {
                            Text("自动").tag(ControlDecision.allow)
                            Text("每次确认").tag(ControlDecision.confirm)
                            Text("拒绝").tag(ControlDecision.deny)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    if tier != ControlTier.allCases.last {
                        Divider()
                    }
                }
                if !service.policy.rememberedGrants.isEmpty {
                    HStack {
                        Text("已记住 \(service.policy.rememberedGrants.count) 条授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("全部清除") { service.forgetAllGrants() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func toolsSummary(for tier: ControlTier) -> String {
        let names = ControlToolID.allCases
            .filter { $0.tier == tier }
            .map(\.displayName)
        return names.isEmpty ? "—" : names.joined(separator: " · ")
    }

    private var pairingPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已配对的 Agent")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("新建配对") { service.createPairing(displayName: "Claude Code") }
                        .controlSize(.small)
                }
                if service.clients.isEmpty {
                    Text("还没有配对。新建一个配对，把生成的一行命令粘到终端即可接入 Claude Code。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.clients) { client in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.displayName)
                                    .font(.system(size: 13))
                                Text(client.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let lastUsed = client.lastUsedAt {
                                    Text("最近使用 \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if client.isRevoked {
                                Text("已撤销")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Button("撤销") { service.revoke(clientID: client.id) }
                                    .controlSize(.small)
                            }
                            Button("删除") { service.remove(clientID: client.id) }
                                .controlSize(.small)
                        }
                        Divider()
                    }
                }
                if let pairing = service.pendingPairing {
                    pairingInstructions(pairing)
                }
            }
        }
    }

    private func pairingInstructions(_ pairing: ComputerControlService.PendingPairing) -> some View {
        let command = service.claudeCodeInstallCommand(for: pairing)
        return VStack(alignment: .leading, spacing: 8) {
            Text("配对已创建。Token 只显示这一次，请立即复制。")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
            HStack {
                Button("复制命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
                Button("我已保存") { service.dismissPendingPairing() }
                    .controlSize(.small)
            }
        }
    }

    private var voicePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("说完就提交")
                    .font(.system(size: 14, weight: .semibold))
                Text("语音仍由你的输入法（如豆包）转成文字。开启后，SayAll 会在语音结束时切换到目标 Agent 应用并按下回车提交。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "语音结束自动提交给 Agent",
                    isOn: Binding(
                        get: { submitter.isEnabled },
                        set: { submitter.update(isEnabled: $0) }
                    )
                )
                HStack {
                    Text("目标应用")
                        .font(.system(size: 13))
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { submitter.targetBundleID },
                            set: { submitter.update(targetBundleID: $0) }
                        )
                    ) {
                        Text("未选择").tag("")
                        ForEach(submitter.candidates, id: \.bundleID) { candidate in
                            Text(candidate.name).tag(candidate.bundleID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                HStack {
                    Text("提交前等待")
                        .font(.system(size: 13))
                    Slider(
                        value: Binding(
                            get: { submitter.settleDelay },
                            set: { submitter.update(settleDelay: $0) }
                        ),
                        in: 0.2...4,
                        step: 0.1
                    )
                    Text(String(format: "%.1fs", submitter.settleDelay))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private var auditPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("审计日志")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("刷新") { service.refreshAudit() }
                        .controlSize(.small)
                    Button("清空") { service.clearAudit() }
                        .controlSize(.small)
                }
                if service.recentEvents.isEmpty {
                    Text("暂无记录。Agent 的每次调用都会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(service.recentEvents.prefix(20).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(for: event.result))
                                .frame(width: 6, height: 6)
                            Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(event.tool)
                                .font(.system(size: 11, design: .monospaced))
                            Text(event.argumentDigest)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(label(for: event.result))
                                .font(.caption2)
                                .foregroundStyle(color(for: event.result))
                        }
                    }
                }
            }
        }
    }

    private func color(for result: ControlAuditEvent.Result) -> Color {
        switch result {
        case .allowed: return .green
        case .confirmed: return .blue
        case .denied: return .orange
        case .failed: return .red
        }
    }

    private func label(for result: ControlAuditEvent.Result) -> String {
        switch result {
        case .allowed: return "已执行"
        case .confirmed: return "已确认"
        case .denied: return "已拒绝"
        case .failed: return "失败"
        }
    }
}

/// Lightweight observable wrapper so the SwiftUI page can react to changes in the
/// submitter, which is a plain main-actor singleton.
@MainActor
final class VoiceAgentSubmitterProxy: ObservableObject {
    static let shared = VoiceAgentSubmitterProxy()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var targetBundleID: String
    @Published private(set) var settleDelay: Double
    @Published private(set) var candidates: [(bundleID: String, name: String)]

    private init() {
        let submitter = VoiceAgentSubmitter.shared
        isEnabled = submitter.isEnabled
        targetBundleID = submitter.targetBundleID
        settleDelay = submitter.settleDelay
        candidates = submitter.candidateApplications()
    }

    func update(isEnabled: Bool? = nil, targetBundleID: String? = nil, settleDelay: Double? = nil) {
        VoiceAgentSubmitter.shared.update(
            isEnabled: isEnabled,
            targetBundleID: targetBundleID,
            settleDelay: settleDelay
        )
        self.isEnabled = VoiceAgentSubmitter.shared.isEnabled
        self.targetBundleID = VoiceAgentSubmitter.shared.targetBundleID
        self.settleDelay = VoiceAgentSubmitter.shared.settleDelay
    }
}
