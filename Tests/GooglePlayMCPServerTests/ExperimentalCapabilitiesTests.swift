import Foundation
import MCP
import Testing

@Suite("Experimental capability compatibility")
struct ExperimentalCapabilitiesTests {
    @Test("Codex initialization accepts object-valued experimental capabilities")
    func codexInitialization() throws {
        let data = Data(
            #"{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}"#
                .utf8)
        let parameters = try JSONDecoder().decode(Initialize.Parameters.self, from: data)
        #expect(parameters.capabilities.experimental?["codex/auth-change"] == .object([:]))
        let encoded = try JSONEncoder().encode(parameters)
        #expect(try JSONDecoder().decode(Initialize.Parameters.self, from: encoded) == parameters)
    }

    @Test("Unknown capability values preserve arbitrary JSON and legacy strings")
    func arbitraryValues() throws {
        let data = Data(
            #"{"experimental":{"object":{"nested":[true,1,null]},"string":"legacy","boolean":true,"number":42,"array":[],"null":null}}"#
                .utf8)
        let capabilities = try JSONDecoder().decode(Client.Capabilities.self, from: data)
        #expect(capabilities.experimental?["string"] == .string("legacy"))
        #expect(capabilities.experimental?["boolean"] == .bool(true))
        #expect(capabilities.experimental?["object"] != nil)
        let encoded = try JSONEncoder().encode(capabilities)
        #expect(try JSONDecoder().decode(Client.Capabilities.self, from: encoded) == capabilities)
    }

    @Test("Missing and empty experimental capabilities still initialize")
    func missingAndEmpty() throws {
        for json in ["{}", #"{"experimental":{}}"#] {
            let capabilities = try JSONDecoder().decode(Client.Capabilities.self, from: Data(json.utf8))
            #expect(capabilities.experimental?.isEmpty ?? true)
        }
    }
}
