import Foundation
import Logging
import MCP

/// Adapts initialization to the SDK's string-only experimental capability model.
/// The server does not implement experimental client features. Ignore unsupported values
/// rather than rejecting hosts that advertise object-valued extensions (upstream PR #276).
actor CapabilityCompatibleTransport: Transport {
    nonisolated let logger: Logger
    private let base: any Transport

    init(_ base: any Transport, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.normalized(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func normalized(_ data: Data) -> Data {
        guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "initialize",
            var params = message["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"] as? [String: Any]
        else { return data }
        capabilities["experimental"] = experimental.filter { $0.value is String }
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
