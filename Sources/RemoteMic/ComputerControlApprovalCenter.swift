import AppKit
import SayAllControlKit
import SwiftUI

/// Presents the confirmation panel for tool calls whose policy is `.confirm`.
/// One request at a time: the panel is modal to the agent's flow, not to the app.
@MainActor
final class ComputerControlApprovalCenter {
    enum Decision: Sendable {
        case allowOnce
        case allowAndRemember
        case deny
        case timedOut
    }

    static let shared = ComputerControlApprovalCenter()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Decision, Never>?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    func request(
        summary: ControlActionSummary,
        clientName: String,
        targetAppName: String?,
        timeout: TimeInterval
    ) async -> Decision {
        // Never stack panels: a second request while one is open is treated as a
        // denial so a runaway agent cannot queue up approvals.
        guard continuation == nil else { return .deny }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(
                summary: summary,
                clientName: clientName,
                targetAppName: targetAppName,
                timeout: timeout
            )
        }
    }

    private func present(
        summary: ControlActionSummary,
        clientName: String,
        targetAppName: String?,
        timeout: TimeInterval
    ) {
        let view = ControlApprovalView(
            summary: summary,
            clientName: clientName,
            targetAppName: targetAppName,
            timeout: timeout,
            onDecision: { [weak self] decision in
                self?.finish(decision)
            }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.timedOut)
        }
    }

    private func finish(_ decision: Decision) {
        timeoutTask?.cancel()
        timeoutTask = nil
        panel?.orderOut(nil)
        panel = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: decision)
    }
}

private struct ControlApprovalView: View {
    let summary: ControlActionSummary
    let clientName: String
    let targetAppName: String?
    let timeout: TimeInterval
    let onDecision: (ComputerControlApprovalCenter.Decision) -> Void

    @State private var remaining: Int

    init(
        summary: ControlActionSummary,
        clientName: String,
        targetAppName: String?,
        timeout: TimeInterval,
        onDecision: @escaping (ComputerControlApprovalCenter.Decision) -> Void
    ) {
        self.summary = summary
        self.clientName = clientName
        self.targetAppName = targetAppName
        self.timeout = timeout
        self.onDecision = onDecision
        _remaining = State(initialValue: Int(timeout))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("AI 请求操作你的电脑")
                    .font(.headline)
                Spacer()
                Text("\(remaining)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.tool.summary)
                    .font(.subheadline.weight(.medium))
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("拒绝") { onDecision(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if summary.tool.tier != .privileged {
                    Button("始终允许") { onDecision(.allowAndRemember) }
                }
                Button("允许一次") { onDecision(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 260)
        .task {
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
        }
    }

    private var context: String {
        var parts = ["来自 \(clientName)"]
        if let targetAppName, !targetAppName.isEmpty {
            parts.append("当前应用：\(targetAppName)")
        }
        return parts.joined(separator: " · ")
    }
}
