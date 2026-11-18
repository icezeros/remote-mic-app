import CryptoKit
import Darwin
import Foundation

public struct SayAllControlPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func defaults(fileManager: FileManager = .default) -> Self {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return Self(
            root: applicationSupport
                .appendingPathComponent("RemoteMic", isDirectory: true)
                .appendingPathComponent("Control", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        )
    }

    /// Unix domain socket the helper connects to. Kept short because `sun_path`
    /// is limited to 104 bytes on macOS.
    public var socketURL: URL {
        root.appendingPathComponent("bridge.sock")
    }

    public var authorizationFileURL: URL {
        root.appendingPathComponent("authorizations.json")
    }

    public var policyFileURL: URL {
        root.appendingPathComponent("policy.json")
    }

    public var auditLogURL: URL {
        root.appendingPathComponent("audit.jsonl")
    }

    public func ensurePrivateRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(root.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public struct ControlAuthorization: Codable, Equatable, Sendable {
    public let clientID: String
    public var displayName: String
    /// SHA-256 of the pairing token. The plain token only exists in the client's
    /// MCP configuration and in the one-time reveal presented in Settings.
    public var tokenHash: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isRevoked: Bool

    public init(
        clientID: String,
        displayName: String,
        tokenHash: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isRevoked: Bool = false
    ) {
        self.clientID = clientID
        self.displayName = displayName
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isRevoked = isRevoked
    }
}

public struct ControlAuthorizationDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var authorizations: [ControlAuthorization]

    public init(version: Int = 1, authorizations: [ControlAuthorization] = []) {
        self.version = version
        self.authorizations = authorizations
    }
}

public enum ControlAuthorizationError: Error, Equatable, Sendable {
    case notAuthorized
    case revoked
    case invalidToken
    case corruptedStore

    public var code: String {
        switch self {
        case .notAuthorized: return "control_not_authorized"
        case .revoked: return "control_authorization_revoked"
        case .invalidToken: return "control_invalid_token"
        case .corruptedStore: return "control_store_corrupted"
        }
    }
}

/// File-backed pairing table shared by the app (writer) and the helper (reader).
public final class ControlAuthorizationStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(paths: SayAllControlPaths = .defaults(), fileManager: FileManager = .default) {
        fileURL = paths.authorizationFileURL
        self.fileManager = fileManager
    }

    public func load() throws -> ControlAuthorizationDocument {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func save(_ document: ControlAuthorizationDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Validates a helper's `clientID` + plaintext token.
    @discardableResult
    public func authorize(clientID: String, token: String) throws -> ControlAuthorization {
        lock.lock()
        defer { lock.unlock() }
        var document = try loadUnlocked()
        guard let index = document.authorizations.firstIndex(where: { $0.clientID == clientID })
        else { throw ControlAuthorizationError.notAuthorized }
        guard !document.authorizations[index].isRevoked else {
            throw ControlAuthorizationError.revoked
        }
        guard ControlTokenHasher.hash(token) == document.authorizations[index].tokenHash else {
            throw ControlAuthorizationError.invalidToken
        }
        document.authorizations[index].lastUsedAt = Date()
        try saveUnlocked(document)
        return document.authorizations[index]
    }

    private func loadUnlocked() throws -> ControlAuthorizationDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ControlAuthorizationDocument()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                ControlAuthorizationDocument.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw ControlAuthorizationError.corruptedStore
        }
    }

    private func saveUnlocked(_ document: ControlAuthorizationDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

public enum ControlTokenHasher {
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
