import Foundation

public struct ControlAuditEvent: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        case allowed
        case denied
        case confirmed
        case failed
    }

    public let occurredAt: Date
    public let clientID: String
    public let tool: String
    public let tier: Int
    public let result: Result
    /// Frontmost app at request time. `nil` means no app context was available.
    public let bundleIdentifier: String?
    /// Digest of the arguments with sensitive values replaced by their length.
    public let argumentDigest: String
    public let durationMilliseconds: Int
    public let reasonCode: String?

    public init(
        occurredAt: Date = Date(),
        clientID: String,
        tool: String,
        tier: Int,
        result: Result,
        bundleIdentifier: String?,
        argumentDigest: String,
        durationMilliseconds: Int,
        reasonCode: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.clientID = clientID
        self.tool = tool
        self.tier = tier
        self.result = result
        self.bundleIdentifier = bundleIdentifier
        self.argumentDigest = argumentDigest
        self.durationMilliseconds = durationMilliseconds
        self.reasonCode = reasonCode
    }
}

/// Append-only audit trail. One JSON object per line, newest last.
public final class ControlAuditLog: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let maximumBytes = 4 * 1024 * 1024

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func append(_ event: ControlAuditEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        try rotateIfNeeded()
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try ensureDirectory()
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    /// Most recent events first, bounded by `limit`.
    public func recent(limit: Int) throws -> [ControlAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [ControlAuditEvent] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard events.count < max(0, limit) else { break }
            if let event = try? decoder.decode(ControlAuditEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        return events
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL)
    }

    private func rotateIfNeeded() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumBytes else { return }
        let archived = fileURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: archived)
        try fileManager.moveItem(at: fileURL, to: archived)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public enum ControlAuditDigest {
    /// Produces a compact, log-safe description of a tool call.
    public static func describe(
        tool: ControlToolID,
        arguments: [String: any Sendable]
    ) -> String {
        let redacted = tool.redactedArguments
        let parts = arguments.keys.sorted().compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            if redacted.contains(key) {
                if let text = value as? String {
                    return "\(key)=<\(text.count) chars>"
                }
                return "\(key)=<redacted>"
            }
            if let text = value as? String {
                return "\(key)=\(text.prefix(64))"
            }
            if let number = value as? NSNumber {
                return "\(key)=\(number)"
            }
            if let list = value as? [String] {
                return "\(key)=[\(list.joined(separator: ","))]"
            }
            return "\(key)=<value>"
        }
        return parts.joined(separator: " ")
    }
}
