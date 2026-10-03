import Foundation
import Logging
import MCP
import Testing

@testable import GooglePlayMCPServer

@Suite("Experimental capability compatibility")
struct ExperimentalCapabilitiesTests {
    @Test("Codex initialization accepts object-valued experimental capabilities")
    func codexInitialization() throws {
        let data = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#
                .utf8)
        let message =
            try JSONSerialization.jsonObject(
                with: CapabilityCompatibleTransport.normalized(data)) as! [String: Any]
        let params = try JSONSerialization.data(withJSONObject: message["params"]!)
        let parameters = try JSONDecoder().decode(Initialize.Parameters.self, from: params)
        #expect(parameters.capabilities.experimental?.isEmpty == true)
        #expect(parameters.capabilities.elicitation?.form != nil)
        #expect(parameters.capabilities.elicitation?.url != nil)
        #expect(parameters.clientInfo.name == "codex-mcp-client")
    }

    @Test("Initialization retains legacy strings and ignores unsupported experimental values")
    func arbitraryValues() throws {
        let data = Data(
            #"{"method":"initialize","params":{"capabilities":{"experimental":{"object":{"nested":[true,1,null]},"string":"legacy","boolean":true,"number":42,"array":[],"null":null}}}}"#
                .utf8)
        let message =
            try JSONSerialization.jsonObject(
                with: CapabilityCompatibleTransport.normalized(data)) as! [String: Any]
        let params = message["params"] as! [String: Any]
        let capabilities = try JSONDecoder().decode(
            Client.Capabilities.self, from: JSONSerialization.data(withJSONObject: params["capabilities"]!))
        #expect(capabilities.experimental == ["string": "legacy"])
    }

    @Test("Other messages and malformed input pass through unchanged")
    func passthrough() {
        for json in ["invalid JSON", #"{"method":"tools/call","params":{"experimental":{"a":{}}}}"#] {
            let data = Data(json.utf8)
            #expect(CapabilityCompatibleTransport.normalized(data) == data)
        }
    }

    @Test("Missing and empty experimental capabilities still initialize")
    func missingAndEmpty() throws {
        for json in ["{}", #"{"experimental":{}}"#] {
            let capabilities = try JSONDecoder().decode(Client.Capabilities.self, from: Data(json.utf8))
            #expect(capabilities.experimental?.isEmpty ?? true)
        }
    }
}

private actor CapabilityTestTransport: Transport {
    nonisolated let logger = Logger(label: "capability-test")
    private(set) var connected = false
    private(set) var sent: [Data] = []
    let messages: [Data]
    let fail: Bool

    init(messages: [Data], fail: Bool = false) {
        self.messages = messages
        self.fail = fail
    }
    func connect() { connected = true }
    func disconnect() { connected = false }
    func send(_ data: Data) { sent.append(data) }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for message in messages { continuation.yield(message) }
            if fail { continuation.finish(throwing: URLError(.timedOut)) } else { continuation.finish() }
        }
    }
}

extension ExperimentalCapabilitiesTests {
    @Test("transport adapts incoming initialization and forwards outgoing traffic and lifecycle")
    func transportLifecycle() async throws {
        let input = Data(#"{"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#.utf8)
        let base = CapabilityTestTransport(messages: [input])
        let transport = CapabilityCompatibleTransport(base, logger: Logger(label: "test"))
        try await transport.connect()
        #expect(await base.connected)
        let outgoing = Data(#"{"result":{"tools":[]}}"#.utf8)
        try await transport.send(outgoing)
        #expect(await base.sent == [outgoing])
        var incoming: [Data] = []
        for try await message in await transport.receive() { incoming.append(message) }
        #expect(incoming.count == 1)
        let received = try JSONSerialization.jsonObject(with: #require(incoming.first)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: CapabilityCompatibleTransport.normalized(input)) as? NSDictionary
        // JSON object key order is unspecified and can differ between serializations on Linux.
        #expect(try #require(received) == #require(expected))
        await transport.disconnect()
        #expect(await !base.connected)
    }

    @Test("transport forwards a receive failure instead of silently ending the connection")
    func transportFailure() async throws {
        let base = CapabilityTestTransport(messages: [], fail: true)
        let transport = CapabilityCompatibleTransport(base, logger: Logger(label: "test"))
        await #expect(throws: URLError.self) {
            for try await _ in await transport.receive() {}
        }
    }
}
