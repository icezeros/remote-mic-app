import Foundation
import SayAllControlKit

private let clientIDEnvironmentKey = "SAYALL_CONTROL_CLIENT_ID"
private let accessTokenEnvironmentKey = "SAYALL_CONTROL_TOKEN"
private let socketPathEnvironmentKey = "SAYALL_CONTROL_SOCKET"

@main
private struct SayAllControlCommand {
    static func main() {
        do {
            try run()
        } catch {
            writeError("sayall-control: \(error)\n")
            Foundation.exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["serve"] else {
            writeError(
                """
                Usage:
                  SayAllControl serve

                Environment:
                  SAYALL_CONTROL_CLIENT_ID   Pairing identifier created in SayAll settings
                  SAYALL_CONTROL_TOKEN       Pairing token for that identifier

                """
            )
            Foundation.exit(2)
        }
        let environment = ProcessInfo.processInfo.environment
        let paths = SayAllControlPaths.defaults()
        let socketPath = environment[socketPathEnvironmentKey] ?? paths.socketURL.path
        let clientID = environment[clientIDEnvironmentKey] ?? ""
        let token = environment[accessTokenEnvironmentKey] ?? ""
        guard !clientID.isEmpty, !token.isEmpty else {
            writeError(
                "sayall-control: SAYALL_CONTROL_CLIENT_ID and SAYALL_CONTROL_TOKEN are required.\n"
            )
            Foundation.exit(2)
        }
        let bridge = ControlBridgeClient(socketPath: socketPath)
        // A cheap probe that surfaces the common "app not running" mistake in the
        // client's log without preventing the server from starting.
        do {
            _ = try bridge.call(
                ControlBridgeRequest(method: .hello, clientID: clientID, token: token)
            )
        } catch {
            writeError(
                "sayall-control: app bridge not reachable yet (\(error)); tools will fail until SayAll is running.\n"
            )
        }
        try ControlMCPStdioServer(
            bridge: bridge,
            clientID: clientID,
            token: token
        ).run()
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
