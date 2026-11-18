import Foundation

/// MCP stdio server exposing the computer-control toolset. It never executes
/// anything itself: every call is forwarded to the running SayAll app, which owns
/// the system permissions and the approval UI.
public final class ControlMCPStdioServer {
    private let bridge: ControlBridgeClient
    private let clientID: String
    private let token: String
    private let negotiatedProtocolVersion = "2025-06-18"
    private var didHandshake = false

    public init(
        bridge: ControlBridgeClient,
        clientID: String,
        token: String
    ) {
        self.bridge = bridge
        self.clientID = clientID
        self.token = token
    }

    public func run() throws {
        writeError("SayAll computer control MCP server is running on stdio.\n")
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                writeResponse([
                    "jsonrpc": "2.0",
                    "id": NSNull(),
                    "error": ["code": -32700, "message": "Parse error"],
                ])
                continue
            }
            handle(request)
        }
    }

    private func handle(_ request: [String: Any]) {
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else {
            writeResponse([
                "jsonrpc": "2.0",
                "id": request["id"] ?? NSNull(),
                "error": ["code": -32600, "message": "Invalid Request"],
            ])
            return
        }
        // Notifications carry no id and must never receive a response.
        guard let identifier = request["id"] else { return }
        let parameters = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            didHandshake = true
            writeResponse([
                "jsonrpc": "2.0",
                "id": identifier,
                "result": [
                    "protocolVersion": negotiatedProtocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": [
                        "name": "sayall_control",
                        "version": ControlVersion.current,
                    ],
                    "instructions": Self.instructions,
                ],
            ])
        case "ping":
            writeResponse(["jsonrpc": "2.0", "id": identifier, "result": [:]])
        case "tools/list":
            writeResponse([
                "jsonrpc": "2.0",
                "id": identifier,
                "result": ["tools": Self.toolList()],
            ])
        case "tools/call":
            handleToolCall(identifier: identifier, parameters: parameters)
        default:
            writeResponse([
                "jsonrpc": "2.0",
                "id": identifier,
                "error": ["code": -32601, "message": "Method not found: \(method)"],
            ])
        }
    }

    private func handleToolCall(identifier: Any, parameters: [String: Any]) {
        guard let name = parameters["name"] as? String,
              let tool = ControlToolID(rawValue: name)
        else {
            writeToolResult(
                identifier: identifier,
                text: "未知工具。",
                isError: true,
                structured: nil
            )
            return
        }
        let rawArguments = parameters["arguments"] as? [String: Any] ?? [:]
        let arguments = rawArguments.mapValues(ControlJSONValue.from)
        let request = ControlBridgeRequest(
            method: .callTool,
            clientID: clientID,
            token: token,
            tool: tool.rawValue,
            arguments: arguments
        )
        do {
            let response = try bridge.call(request)
            if response.ok {
                let result = response.result ?? .null
                writeToolResult(
                    identifier: identifier,
                    text: Self.textSummary(for: result),
                    isError: false,
                    structured: result
                )
            } else {
                let failure = response.error
                writeToolResult(
                    identifier: identifier,
                    text: failure?.message ?? "执行失败。",
                    isError: true,
                    structured: .object([
                        "error_code": .string(failure?.code ?? "unknown"),
                        "user_denied": .bool(failure?.userDenied ?? false),
                    ])
                )
            }
        } catch let error as ControlBridgeError {
            writeToolResult(
                identifier: identifier,
                text: error.message,
                isError: true,
                structured: .object(["error_code": .string(error.code)])
            )
        } catch {
            writeToolResult(
                identifier: identifier,
                text: "执行失败：\(error.localizedDescription)",
                isError: true,
                structured: nil
            )
        }
    }

    private func writeToolResult(
        identifier: Any,
        text: String,
        isError: Bool,
        structured: ControlJSONValue?
    ) {
        var result: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
        if let structured,
           let data = try? JSONEncoder().encode(structured),
           let object = try? JSONSerialization.jsonObject(with: data) {
            result["structuredContent"] = object
        }
        writeResponse(["jsonrpc": "2.0", "id": identifier, "result": result])
    }

    private func writeResponse(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.withoutEscapingSlashes]
              )
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    static func toolList() -> [[String: Any]] {
        ControlToolDescriptor.all.map { descriptor in
            var entry: [String: Any] = [
                "name": descriptor.tool.rawValue,
                "description": descriptor.summary,
                "inputSchema": (try? JSONSerialization.jsonObject(
                    with: Data(descriptor.inputSchemaJSON.utf8)
                )) ?? ["type": "object"],
            ]
            entry["annotations"] = [
                "title": descriptor.tool.summary,
                "readOnlyHint": descriptor.tier == .read,
                "destructiveHint": descriptor.tier == .privileged,
                "openWorldHint": true,
            ]
            return entry
        }
    }

    static func textSummary(for value: ControlJSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .object(let object):
            if let message = object["message"]?.stringValue { return message }
            if let data = try? JSONEncoder().encode(ControlJSONValue.object(object)),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "完成。"
        case .array(let values):
            if let data = try? JSONEncoder().encode(ControlJSONValue.array(values)),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "完成。"
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "完成。"
        }
    }

    static let instructions = """
    这些工具可以直接操作这台 Mac：切换应用、输入文字、发送快捷键、点击、读取界面元素。
    使用规则：
    1. 先观察（list_running_apps / get_frontmost_app / get_ui_tree），再动手。
    2. 每次只做一个可解释的小动作，做完确认结果；不要在用户不知情时连续操作。
    3. 用户可能会在 SayAll 的确认弹窗里拒绝，收到 user_denied 就停止并说明原因。
    4. run_applescript 默认被禁用，不要尝试绕过或反复重试。
    """
}

public enum ControlVersion {
    public static let current = "1.0.0"
}
