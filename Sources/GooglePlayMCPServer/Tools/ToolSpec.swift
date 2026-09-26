import Foundation
import GoogleAuthKit
import GooglePlayKit
import MCP

extension Tool.Content {
    /// A plain text content block.
    ///
    /// The SDK's `.text(_:)` / `.text(text:metadata:)` convenience factories are deprecated in
    /// favour of the three-argument case; this keeps call sites short without reaching for a
    /// deprecated overload.
    static func plainText(_ text: String) -> Self {
        .text(text: text, annotations: nil, _meta: nil)
    }
}

/// One argument of a ``ToolSpec``, from which the JSON Schema is generated.
struct ToolArgument: Sendable {
    /// The JSON Schema primitive type this argument accepts.
    enum Kind: String, Sendable {
        case string
        case integer
        case number
        case boolean
    }

    let name: String
    let kind: Kind
    let description: String
    let isRequired: Bool
    /// The only values the argument accepts, advertised as the schema's `enum`.
    var allowedValues: [String]? = nil
    /// Inclusive numeric bounds (`minimum` / `maximum`).
    var minimum: Double? = nil
    var maximum: Double? = nil
    /// Exclusive numeric bounds (`exclusiveMinimum` / `exclusiveMaximum`), for ranges like Play's
    /// `0 < userFraction < 1` that inclusive bounds cannot express.
    var exclusiveMinimum: Double? = nil
    var exclusiveMaximum: Double? = nil

    static func string(
        _ name: String,
        _ description: String,
        required: Bool = false,
        allowedValues: [String]? = nil
    ) -> ToolArgument {
        ToolArgument(
            name: name, kind: .string, description: description, isRequired: required, allowedValues: allowedValues)
    }

    static func integer(_ name: String, _ description: String, minimum: Int? = nil, maximum: Int? = nil) -> ToolArgument {
        ToolArgument(
            name: name, kind: .integer, description: description, isRequired: false,
            minimum: minimum.map { Double($0) }, maximum: maximum.map { Double($0) })
    }

    static func number(
        _ name: String,
        _ description: String,
        required: Bool = false,
        exclusiveMinimum: Double? = nil,
        exclusiveMaximum: Double? = nil
    ) -> ToolArgument {
        ToolArgument(
            name: name, kind: .number, description: description, isRequired: required,
            exclusiveMinimum: exclusiveMinimum, exclusiveMaximum: exclusiveMaximum)
    }

    /// This argument's JSON Schema property.
    var schema: Value {
        var property: [String: Value] = [
            "type": .string(kind.rawValue),
            "description": .string(description),
        ]
        if let allowedValues {
            property["enum"] = .array(allowedValues.map { Value.string($0) })
        }
        let bounds: [(String, Double?)] = [
            ("minimum", minimum), ("maximum", maximum),
            ("exclusiveMinimum", exclusiveMinimum), ("exclusiveMaximum", exclusiveMaximum),
        ]
        for case (let key, let bound?) in bounds {
            // Integer bounds stay integers so the schema reads `"maximum": 100`, not `100.0`.
            property[key] = kind == .integer ? .int(Int(bound)) : .double(bound)
        }
        return .object(property)
    }

    static func boolean(_ name: String, _ description: String) -> ToolArgument {
        ToolArgument(name: name, kind: .boolean, description: description, isRequired: false)
    }
}

/// Typed access to the arguments of one tool call.
struct ToolArguments: Sendable {
    private let values: [String: Value]
    private let defaultPackageName: String?

    init(_ values: [String: Value], defaultPackageName: String? = nil) {
        self.values = values
        self.defaultPackageName = defaultPackageName
    }

    /// The `packageName` argument, or the server's configured default when the call omits it.
    ///
    /// An explicit argument always wins, so an agent can still reach a second app in a session
    /// configured for the first.
    func packageName() throws -> String {
        if let explicit = string("packageName") { return explicit }
        if let defaultPackageName { return defaultPackageName }
        throw GoogleAPIError.invalidConfiguration(
            reason: """
                Missing required argument 'packageName'. Pass it, or set GOOGLE_PLAY_PACKAGE_NAME in the \
                server's environment to default it.
                """
        )
    }

    /// A required string argument.
    ///
    /// - Throws: ``GoogleAPIError/invalidConfiguration(reason:)`` when absent or empty, so a
    ///   caller that forgot an argument gets a usable message instead of a decode error.
    func require(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw GoogleAPIError.invalidConfiguration(reason: "Missing required argument '\(key)'.")
        }
        return value
    }

    /// An optional string argument. Empty strings read as absent.
    func string(_ key: String) -> String? {
        guard let value = values[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// An optional integer argument, falling back to `defaultValue`.
    ///
    /// The value is clamped to `1...max`: a host that sends `maxResults: 0` would otherwise get
    /// an empty list back with no explanation.
    func int(_ key: String, default defaultValue: Int, max maxValue: Int = 100) -> Int {
        guard let raw = number(key).map({ Int($0) }) else { return defaultValue }
        return min(max(raw, 1), maxValue)
    }

    /// A required floating-point argument.
    func requireDouble(_ key: String) throws -> Double {
        guard let value = number(key) else {
            throw GoogleAPIError.invalidConfiguration(reason: "Missing required numeric argument '\(key)'.")
        }
        return value
    }

    /// Reads a numeric argument regardless of how the host encoded it.
    ///
    /// `Value.doubleValue` only matches the `.double` case, but JSON `1.0` decodes as `.int` —
    /// so reading a fraction of exactly `1.0` through `doubleValue` alone yields nil and reports
    /// a *missing* argument for one that was supplied. Some hosts also stringify numbers.
    private func number(_ key: String) -> Double? {
        guard let value = values[key] else { return nil }
        if let double = value.doubleValue { return double }
        if let int = value.intValue { return Double(int) }
        if let text = value.stringValue, let parsed = Double(text) { return parsed }
        return nil
    }
}

/// A tool's schema and its implementation, declared together.
///
/// Keeping the two in one value means the catalog the server advertises and the dispatcher that
/// serves it cannot drift apart — there is no separate `switch` to forget a case in, and the JSON
/// Schema is derived from the same argument list the handler reads.
struct ToolSpec: Sendable {
    typealias Handler = @Sendable (ToolArguments, PlayTools.ClientProvider) async throws -> CallTool.Result

    let name: String
    let description: String
    let arguments: [ToolArgument]
    /// Whether the tool only reads. Advertised to the host as `readOnlyHint`, which is what lets
    /// a client auto-approve a lookup instead of prompting for every call.
    let isReadOnly: Bool
    let handler: Handler

    init(
        name: String,
        description: String,
        arguments: [ToolArgument] = [],
        isReadOnly: Bool = true,
        handler: @escaping Handler
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.isReadOnly = isReadOnly
        self.handler = handler
    }

    /// The MCP tool advertised to the host, with its schema generated from ``arguments``.
    var tool: Tool {
        var properties: [String: Value] = [:]
        for argument in arguments {
            properties[argument.name] = argument.schema
        }

        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        let required = arguments.filter(\.isRequired).map { Value.string($0.name) }
        if !required.isEmpty {
            schema["required"] = .array(required)
        }

        return Tool(
            name: name,
            description: description,
            inputSchema: .object(schema),
            annotations: .init(
                readOnlyHint: isReadOnly,
                destructiveHint: !isReadOnly,
                idempotentHint: isReadOnly,
                // Every tool talks to Google's servers, whose state this server does not own.
                openWorldHint: true
            )
        )
    }
}
