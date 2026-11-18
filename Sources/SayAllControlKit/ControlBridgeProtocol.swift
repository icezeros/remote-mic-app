import Darwin
import Foundation

/// One request travelling from the MCP helper to the running app over the
/// Unix domain socket. The app is the only process that holds Accessibility and
/// Input Monitoring grants, so every mutation round-trips through it.
public struct ControlBridgeRequest: Codable, Sendable {
    public enum Method: String, Codable, Sendable {
        case hello
        case listTools = "tools/list"
        case callTool = "tools/call"
        case ping
    }

    public let id: String
    public let method: Method
    public let clientID: String?
    public let token: String?
    public let tool: String?
    public let arguments: [String: ControlJSONValue]?

    public init(
        id: String = UUID().uuidString,
        method: Method,
        clientID: String? = nil,
        token: String? = nil,
        tool: String? = nil,
        arguments: [String: ControlJSONValue]? = nil
    ) {
        self.id = id
        self.method = method
        self.clientID = clientID
        self.token = token
        self.tool = tool
        self.arguments = arguments
    }
}

public struct ControlBridgeResponse: Codable, Sendable {
    public struct Failure: Codable, Sendable {
        public let code: String
        public let message: String
        /// `true` when the user actively declined, as opposed to a policy or
        /// transport error. Clients can surface this differently.
        public let userDenied: Bool?

        public init(code: String, message: String, userDenied: Bool? = nil) {
            self.code = code
            self.message = message
            self.userDenied = userDenied
        }
    }

    public let id: String
    public let ok: Bool
    public let result: ControlJSONValue?
    public let error: Failure?

    public init(
        id: String,
        ok: Bool,
        result: ControlJSONValue? = nil,
        error: Failure? = nil
    ) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(id: String, result: ControlJSONValue) -> Self {
        .init(id: id, ok: true, result: result)
    }

    public static func failure(
        id: String,
        code: String,
        message: String,
        userDenied: Bool? = nil
    ) -> Self {
        .init(
            id: id,
            ok: false,
            error: Failure(code: code, message: message, userDenied: userDenied)
        )
    }
}

/// Minimal JSON value used on the wire so the kit stays AppKit-free and does not
/// depend on `Any` casting at the protocol boundary.
public enum ControlJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([ControlJSONValue])
    case object([String: ControlJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ControlJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ControlJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: ControlJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public static func from(_ value: Any) -> ControlJSONValue {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as [Any]: return .array(value.map(from))
        case let value as [String: Any]:
            return .object(value.mapValues(from))
        default: return .null
        }
    }
}

public enum ControlBridgeCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

public enum ControlBridgeError: Error, Equatable, Sendable {
    case socketUnavailable
    case connectionFailed(Int32)
    case sendFailed
    case receiveFailed
    case timedOut
    case malformedResponse
    case remote(String)

    public var code: String {
        switch self {
        case .socketUnavailable: return "control_app_not_running"
        case .connectionFailed: return "control_connect_failed"
        case .sendFailed: return "control_send_failed"
        case .receiveFailed: return "control_receive_failed"
        case .timedOut: return "control_timeout"
        case .malformedResponse: return "control_malformed_response"
        case .remote(let code): return code
        }
    }

    public var message: String {
        switch self {
        case .socketUnavailable:
            return "SayAll 未在运行，或电脑控制桥未启用。请先打开 SayAll 并在设置中启用「语音电脑助手」。"
        case .connectionFailed(let errno):
            return "无法连接 SayAll 控制桥（errno \(errno)）。"
        case .sendFailed: return "发送请求失败。"
        case .receiveFailed: return "读取响应失败。"
        case .timedOut: return "等待用户确认超时。"
        case .malformedResponse: return "响应格式无法解析。"
        case .remote(let code): return "远程执行失败（\(code)）。"
        }
    }
}

/// Blocking UDS client used by the helper process. Connects per call; the socket
/// is cheap and this keeps reconnection semantics trivial.
public struct ControlBridgeClient: Sendable {
    private let socketPath: String
    private let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 120) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func call(_ request: ControlBridgeRequest) throws -> ControlBridgeResponse {
        let descriptor = try connect()
        defer { Darwin.close(descriptor) }
        var payload = try ControlBridgeCodec.encodeLine(request)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlBridgeError.sendFailed
                }
                offset += written
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
        let line = try readLine(descriptor: descriptor)
        guard !line.isEmpty else { throw ControlBridgeError.malformedResponse }
        do {
            return try ControlBridgeCodec.decode(ControlBridgeResponse.self, from: line)
        } catch {
            throw ControlBridgeError.malformedResponse
        }
    }

    private func connect() throws -> Int32 {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ControlBridgeError.socketUnavailable
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlBridgeError.connectionFailed(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw ControlBridgeError.socketUnavailable
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
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ControlBridgeError.connectionFailed(code)
        }
        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeoutValue,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return descriptor
    }

    private func readLine(descriptor: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ControlBridgeError.timedOut
                }
                throw ControlBridgeError.receiveFailed
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }
            if buffer.count > 1_048_576 { throw ControlBridgeError.malformedResponse }
        }
        if let newline = buffer.firstIndex(of: 0x0A) {
            return buffer[buffer.startIndex..<newline]
        }
        return buffer
    }
}
