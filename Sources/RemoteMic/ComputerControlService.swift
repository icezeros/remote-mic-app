import AppKit
import Combine
import Darwin
import Foundation
import SayAllControlKit

/// Owns the computer-control bridge inside the app process.
///
/// The MCP helper is a separate process without system permissions, so it forwards
/// every call here over a Unix domain socket. This class is the only place that
/// evaluates policy, asks the user, executes, and writes the audit trail.
@MainActor
final class ComputerControlService: ObservableObject {
    /// One process-wide instance: the bridge owns a listening socket, so a second
    /// instance would collide on the same path.
    static let shared = ComputerControlService()

    struct ClientSummary: Identifiable, Equatable {
        let id: String
        let displayName: String
        let createdAt: Date
        let lastUsedAt: Date?
        let isRevoked: Bool
    }

    struct PendingPairing {
        let clientID: String
        let displayName: String
        /// Shown once, never persisted in plain text.
        let token: String
    }

    @Published private(set) var policy: ControlPolicy = ControlPolicy()
    @Published private(set) var isBridgeRunning = false
    @Published private(set) var clients: [ClientSummary] = []
    @Published private(set) var recentEvents: [ControlAuditEvent] = []
    @Published private(set) var lastError: String?
    @Published private(set) var pendingPairing: PendingPairing?

    private let paths: SayAllControlPaths
    private let authorizationStore: ControlAuthorizationStore
    private let auditLog: ControlAuditLog
    private let executor: ComputerControlExecutor
    private let logger: (String) -> Void

    private var listenDescriptor: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "app.sayall.control.bridge")
    private var isAccepting = false
    private let policyLock = NSLock()

    init(
        paths: SayAllControlPaths = .defaults(),
        logger: @escaping (String) -> Void = { AppLogger.shared.write($0) }
    ) {
        self.paths = paths
        authorizationStore = ControlAuthorizationStore(paths: paths)
        auditLog = ControlAuditLog(fileURL: paths.auditLogURL)
        executor = ComputerControlExecutor()
        self.logger = logger
        loadPolicy()
        refreshClients()
        if policy.isEnabled {
            startBridge()
        }
    }

    // MARK: - Policy

    private func loadPolicy() {
        guard let data = try? Data(contentsOf: paths.policyFileURL),
              let decoded = try? JSONDecoder().decode(ControlPolicy.self, from: data)
        else {
            policy = ControlPolicy()
            return
        }
        policy = decoded
    }

    func updatePolicy(_ mutate: (inout ControlPolicy) -> Void) {
        var updated = policy
        mutate(&updated)
        policy = updated
        persistPolicy()
        if updated.isEnabled, !isBridgeRunning {
            startBridge()
        } else if !updated.isEnabled, isBridgeRunning {
            stopBridge()
        }
    }

    private func persistPolicy() {
        policyLock.lock()
        defer { policyLock.unlock() }
        do {
            try paths.ensurePrivateRoot()
            let data = try JSONEncoder().encode(policy)
            try data.write(to: paths.policyFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.policyFileURL.path
            )
        } catch {
            lastError = "保存策略失败：\(error.localizedDescription)"
        }
    }

    func setDecision(_ decision: ControlDecision, for tier: ControlTier) {
        updatePolicy { policy in
            policy.setDecision(decision, forTier: tier)
            policy.pruneGrants(whenTighteningTo: tier, decision: decision)
        }
    }

    func forgetAllGrants() {
        updatePolicy { $0.forgetAllGrants() }
    }

    // MARK: - Pairing

    func createPairing(displayName: String) {
        let clientID = UUID().uuidString.lowercased()
        let token = ControlTokenHasher.generateToken()
        do {
            var document = try authorizationStore.load()
            document.authorizations.append(
                ControlAuthorization(
                    clientID: clientID,
                    displayName: displayName,
                    tokenHash: ControlTokenHasher.hash(token)
                )
            )
            try authorizationStore.save(document)
            pendingPairing = PendingPairing(
                clientID: clientID,
                displayName: displayName,
                token: token
            )
            refreshClients()
            logger("[control] paired client \(clientID)")
        } catch {
            lastError = "创建配对失败：\(error.localizedDescription)"
        }
    }

    func dismissPendingPairing() {
        pendingPairing = nil
    }

    func revoke(clientID: String) {
        do {
            var document = try authorizationStore.load()
            guard let index = document.authorizations.firstIndex(where: { $0.clientID == clientID })
            else { return }
            document.authorizations[index].isRevoked = true
            try authorizationStore.save(document)
            refreshClients()
            logger("[control] revoked client \(clientID)")
        } catch {
            lastError = "撤销授权失败：\(error.localizedDescription)"
        }
    }

    func remove(clientID: String) {
        do {
            var document = try authorizationStore.load()
            document.authorizations.removeAll { $0.clientID == clientID }
            try authorizationStore.save(document)
            refreshClients()
        } catch {
            lastError = "删除授权失败：\(error.localizedDescription)"
        }
    }

    private func refreshClients() {
        guard let document = try? authorizationStore.load() else { return }
        clients = document.authorizations.map {
            ClientSummary(
                id: $0.clientID,
                displayName: $0.displayName,
                createdAt: $0.createdAt,
                lastUsedAt: $0.lastUsedAt,
                isRevoked: $0.isRevoked
            )
        }
    }

    /// Ready-to-paste Claude Code command for the pairing just created.
    func claudeCodeInstallCommand(for pairing: PendingPairing) -> String {
        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SayAllControl").path
        let server: [String: Any] = [
            "type": "stdio",
            "command": helperPath,
            "args": ["serve"],
            "env": [
                "SAYALL_CONTROL_CLIENT_ID": pairing.clientID,
                "SAYALL_CONTROL_TOKEN": pairing.token,
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: server,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "claude mcp add-json --scope user sayall_control '\(json)'"
    }

    // MARK: - Audit

    func refreshAudit(limit: Int = 60) {
        recentEvents = (try? auditLog.recent(limit: limit)) ?? []
    }

    func clearAudit() {
        try? auditLog.removeAll()
        recentEvents = []
    }

    // MARK: - Socket lifecycle

    func startBridge() {
        guard !isBridgeRunning else { return }
        do {
            try paths.ensurePrivateRoot()
            try? FileManager.default.removeItem(at: paths.socketURL)
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(paths.socketURL.path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                Darwin.close(descriptor)
                lastError = "控制桥路径过长，请缩短用户名或目录名。"
                return
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { buffer in
                    for (index, byte) in pathBytes.enumerated() {
                        buffer[index] = CChar(bitPattern: byte)
                    }
                    buffer[pathBytes.count] = 0
                }
            }
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(descriptor, socketAddress, length)
                }
            }
            guard bindResult == 0 else {
                let code = errno
                Darwin.close(descriptor)
                lastError = "控制桥绑定失败（errno \(code)）。"
                return
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                lastError = "控制桥监听失败（errno \(code)）。"
                return
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.socketURL.path
            )
            listenDescriptor = descriptor
            isAccepting = true
            isBridgeRunning = true
            lastError = nil
            acceptQueue.async { [weak self] in
                self?.acceptLoop()
            }
            logger("[control] bridge listening at \(paths.socketURL.path)")
        } catch {
            lastError = "启动控制桥失败：\(error.localizedDescription)"
        }
    }

    func stopBridge() {
        guard isBridgeRunning else { return }
        isAccepting = false
        if listenDescriptor >= 0 {
            Darwin.shutdown(listenDescriptor, SHUT_RDWR)
            Darwin.close(listenDescriptor)
            listenDescriptor = -1
        }
        try? FileManager.default.removeItem(at: paths.socketURL)
        isBridgeRunning = false
        logger("[control] bridge stopped")
    }

    private func acceptLoop() {
        while isAccepting {
            let client = Darwin.accept(listenDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                break
            }
            handleConnection(client)
            Darwin.close(client)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard let line = readLine(descriptor: descriptor) else {
            writeResponse(
                ControlBridgeResponse.failure(
                    id: "",
                    code: "control_bad_request",
                    message: "请求为空或无法读取。"
                ),
                to: descriptor
            )
            return
        }
        guard let request = try? ControlBridgeCodec.decode(ControlBridgeRequest.self, from: line)
        else {
            writeResponse(
                ControlBridgeResponse.failure(
                    id: "",
                    code: "control_bad_request",
                    message: "请求格式无法解析。"
                ),
                to: descriptor
            )
            return
        }
        let response = runBlocking(request)
        writeResponse(response, to: descriptor)
    }

    /// Bridges the synchronous socket thread to the main actor.
    private func runBlocking(_ request: ControlBridgeRequest) -> ControlBridgeResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var output: ControlBridgeResponse?
        Task { @MainActor in
            output = await self.process(request)
            semaphore.signal()
        }
        // Approval timeouts are enforced inside the confirmation panel; the extra
        // headroom here only protects against a wedged main thread.
        let wait = DispatchTime.now() + .seconds(Int(policy.approvalTimeoutSeconds) + 15)
        if semaphore.wait(timeout: wait) == .timedOut {
            return .failure(
                id: request.id,
                code: "control_timeout",
                message: "等待确认超时。"
            )
        }
        return output ?? .failure(
            id: request.id,
            code: "control_no_response",
            message: "内部错误：没有产生响应。"
        )
    }

    private func process(_ request: ControlBridgeRequest) async -> ControlBridgeResponse {
        let started = Date()
        do {
            guard let clientID = request.clientID, let token = request.token else {
                return .failure(
                    id: request.id,
                    code: "control_not_authorized",
                    message: "缺少客户端凭据。"
                )
            }
            let authorization = try authorizationStore.authorize(clientID: clientID, token: token)
            switch request.method {
            case .hello, .ping:
                return .success(
                    id: request.id,
                    result: .object([
                        "ok": .bool(true),
                        "server": .string("sayall_control"),
                        "version": .string(ControlVersion.current),
                    ])
                )
            case .listTools:
                return .success(
                    id: request.id,
                    result: .object([
                        "tools": .array(
                            ControlToolDescriptor.all.map { descriptor in
                                .object([
                                    "name": .string(descriptor.tool.rawValue),
                                    "tier": .number(Double(descriptor.tier.rawValue)),
                                    "summary": .string(descriptor.summary),
                                ])
                            }
                        ),
                    ])
                )
            case .callTool:
                return await callTool(
                    request,
                    authorization: authorization,
                    started: started
                )
            }
        } catch let error as ControlAuthorizationError {
            return .failure(id: request.id, code: error.code, message: "授权无效或已被撤销。")
        } catch {
            return .failure(
                id: request.id,
                code: "control_internal_error",
                message: error.localizedDescription
            )
        }
    }

    private func callTool(
        _ request: ControlBridgeRequest,
        authorization: ControlAuthorization,
        started: Date
    ) async -> ControlBridgeResponse {
        guard let rawTool = request.tool, let tool = ControlToolID(rawValue: rawTool) else {
            return .failure(id: request.id, code: "control_unknown_tool", message: "未知工具。")
        }
        let arguments = request.arguments ?? [:]
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = frontmost?.bundleIdentifier
        let decision = policy.decision(for: tool, bundleIdentifier: bundleIdentifier)
        let summary = ControlActionSummary.make(tool: tool, arguments: arguments)

        if decision == .deny {
            record(
                tool: tool,
                clientID: authorization.clientID,
                result: .denied,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                started: started,
                reason: policy.isEnabled ? "policy_denied" : "feature_disabled"
            )
            return .failure(
                id: request.id,
                code: policy.isEnabled ? "control_policy_denied" : "control_disabled",
                message: policy.isEnabled
                    ? "当前策略不允许这个操作（\(tool.tier.localizedName)）。"
                    : "语音电脑助手未启用。",
                userDenied: true
            )
        }

        if decision == .confirm {
            let approval = await ComputerControlApprovalCenter.shared.request(
                summary: summary,
                clientName: authorization.displayName,
                targetAppName: frontmost?.localizedName,
                timeout: policy.approvalTimeoutSeconds
            )
            switch approval {
            case .allowOnce:
                break
            case .allowAndRemember:
                updatePolicy { policy in
                    policy.remember(tool, bundleIdentifier: bundleIdentifier)
                }
            case .deny:
                record(
                    tool: tool,
                    clientID: authorization.clientID,
                    result: .denied,
                    bundleIdentifier: bundleIdentifier,
                    arguments: arguments,
                    started: started,
                    reason: "user_denied"
                )
                return .failure(
                    id: request.id,
                    code: "control_user_denied",
                    message: "用户拒绝了这次操作。",
                    userDenied: true
                )
            case .timedOut:
                record(
                    tool: tool,
                    clientID: authorization.clientID,
                    result: .denied,
                    bundleIdentifier: bundleIdentifier,
                    arguments: arguments,
                    started: started,
                    reason: "approval_timeout"
                )
                return .failure(
                    id: request.id,
                    code: "control_approval_timeout",
                    message: "用户在限定时间内没有确认。",
                    userDenied: true
                )
            }
        }

        do {
            let result = try executor.execute(tool: tool, arguments: arguments)
            record(
                tool: tool,
                clientID: authorization.clientID,
                result: .allowed,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                started: started,
                reason: nil
            )
            refreshClients()
            return .success(id: request.id, result: result)
        } catch let error as ControlExecutionError {
            record(
                tool: tool,
                clientID: authorization.clientID,
                result: .failed,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                started: started,
                reason: error.code
            )
            return .failure(id: request.id, code: error.code, message: error.message)
        } catch {
            record(
                tool: tool,
                clientID: authorization.clientID,
                result: .failed,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                started: started,
                reason: "control_execution_failed"
            )
            return .failure(
                id: request.id,
                code: "control_execution_failed",
                message: error.localizedDescription
            )
        }
    }

    private func record(
        tool: ControlToolID,
        clientID: String,
        result: ControlAuditEvent.Result,
        bundleIdentifier: String?,
        arguments: [String: ControlJSONValue],
        started: Date,
        reason: String?
    ) {
        let event = ControlAuditEvent(
            clientID: clientID,
            tool: tool.rawValue,
            tier: tool.tier.rawValue,
            result: result,
            bundleIdentifier: bundleIdentifier,
            argumentDigest: ControlAuditDigest.describe(
                tool: tool,
                arguments: arguments.mapValues { $0 as any Sendable }
            ),
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            reasonCode: reason
        )
        try? auditLog.append(event)
        refreshAudit()
    }

    // MARK: - Socket IO

    private func readLine(descriptor: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }
            if buffer.count > 1_048_576 { break }
        }
        guard !buffer.isEmpty else { return nil }
        if let newline = buffer.firstIndex(of: 0x0A) {
            return buffer[buffer.startIndex..<newline]
        }
        return buffer
    }

    private func writeResponse(_ response: ControlBridgeResponse, to descriptor: Int32) {
        guard let data = try? ControlBridgeCodec.encodeLine(response) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}
