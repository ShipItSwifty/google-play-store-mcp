import Foundation
import GoogleAuthKit
import GooglePlayKit
import MCP
import Testing

@testable import GooglePlayMCPServer

/// A client provider that fails if a tool ever actually reaches for the network — used by the
/// tests that only exercise dispatch and gating.
private let unusedClient: PlayTools.ClientProvider = {
    throw GoogleAPIError.invalidConfiguration(reason: "client should not be constructed in this test")
}

@Suite("MCP tool catalog")
struct PlayToolCatalogTests {

    @Test("read tools are advertised as read-only, write tools are not")
    func annotationsMatchIntent() {
        for spec in PlayTools.readSpecs {
            #expect(spec.isReadOnly, "\(spec.name) should be read-only")
        }
        for spec in PlayTools.writeSpecs {
            #expect(!spec.isReadOnly, "\(spec.name) should not be read-only")
        }
    }

    @Test("writes are gated off by default")
    func writeToolsHiddenByDefault() {
        let advertised = PlayTools.specs(writesEnabled: false).map(\.name)

        #expect(advertised.contains("play_list_tracks"))
        #expect(!advertised.contains("play_upload_and_release"))
        #expect(!advertised.contains("play_halt_rollout"))
        #expect(advertised.count == PlayTools.readSpecs.count)
    }

    @Test("enabling writes advertises every tool")
    func writeToolsAppearWhenEnabled() {
        let advertised = PlayTools.specs(writesEnabled: true).map(\.name)

        #expect(advertised.contains("play_upload_and_release"))
        #expect(advertised.count == PlayTools.allSpecs.count)
    }

    @Test(
        "GOOGLE_PLAY_ENABLE_WRITES accepts the usual truthy spellings",
        arguments: [
            ("1", true), ("true", true), ("TRUE", true), ("yes", true),
            ("0", false), ("false", false), ("", false), ("no", false),
        ])
    func writeGateParsing(value: String, expected: Bool) {
        #expect(PlayTools.writesEnabled(["GOOGLE_PLAY_ENABLE_WRITES": value]) == expected)
    }

    @Test("an unset gate is off")
    func writeGateDefaultsOff() {
        #expect(PlayTools.writesEnabled([:]) == false)
    }

    @Test("tool names are unique")
    func toolNamesAreUnique() {
        let names = PlayTools.allSpecs.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every tool accepts packageName, optional in the schema so GOOGLE_PLAY_PACKAGE_NAME can default it")
    func schemaDeclaresPackageName() throws {
        for spec in PlayTools.allSpecs {
            guard case .object(let root) = spec.tool.inputSchema, case .object(let properties)? = root["properties"]
            else {
                Issue.record("\(spec.name) has no properties")
                continue
            }
            #expect(properties["packageName"] != nil, "\(spec.name) should accept packageName")
            if case .array(let required)? = root["required"] {
                #expect(!required.contains(.string("packageName")), "\(spec.name) should not require packageName")
            }
        }
    }

    @Test(
        "GOOGLE_PLAY_PACKAGE_NAME is read, trimmed, and ignored when blank",
        arguments: [
            (["GOOGLE_PLAY_PACKAGE_NAME": "com.example.app"], "com.example.app" as String?),
            (["GOOGLE_PLAY_PACKAGE_NAME": "  com.example.app "], "com.example.app"),
            (["GOOGLE_PLAY_PACKAGE_NAME": "   "], nil),
            ([:], nil),
        ])
    func defaultPackageNameParsing(environment: [String: String], expected: String?) {
        #expect(PlayTools.defaultPackageName(environment) == expected)
    }
}

@Suite("Tool argument schema")
struct ToolArgumentSchemaTests {

    /// The JSON Schema property a tool advertises for one argument.
    private func property(_ argument: String, of tool: String) throws -> [String: Value] {
        let spec = try #require(PlayTools.allSpecs.first { $0.name == tool })
        guard case .object(let root) = spec.tool.inputSchema,
            case .object(let properties)? = root["properties"],
            case .object(let property)? = properties[argument]
        else {
            throw GoogleAPIError.invalidConfiguration(reason: "\(tool) has no \(argument) property")
        }
        return property
    }

    @Test("status advertises exactly the release statuses the handler accepts")
    func statusIsAnEnum() throws {
        let status = try property("status", of: "play_upload_and_release")
        #expect(status["enum"] == .array(PlayTools.releaseStatuses.map { Value.string($0) }))
        // Every advertised value must decode, or the schema would invite a call that fails.
        for raw in PlayTools.releaseStatuses {
            #expect(GooglePlayReleaseStatus(rawValue: raw) != nil, "\(raw) is not a release status")
        }
    }

    @Test(
        "userFraction advertises Play's exclusive (0, 1) range",
        arguments: ["play_upload_and_release", "play_update_rollout", "play_resume_rollout", "play_promote_release"])
    func userFractionIsExclusive(tool: String) throws {
        let fraction = try property("userFraction", of: tool)
        #expect(fraction["exclusiveMinimum"] == .double(0))
        #expect(fraction["exclusiveMaximum"] == .double(1))
        #expect(fraction["minimum"] == nil)
    }

    @Test("maxResults advertises integer bounds matching the clamp")
    func maxResultsIsBounded() throws {
        let maxResults = try property("maxResults", of: "play_list_reviews")
        #expect(maxResults["type"] == .string("integer"))
        #expect(maxResults["minimum"] == .int(1))
        #expect(maxResults["maximum"] == .int(PlayTools.maxReviews))
    }

    @Test("an unconstrained argument carries no constraint keys")
    func plainArgumentHasNoConstraints() throws {
        let track = try property("track", of: "play_get_track")
        #expect(Set(track.keys) == ["type", "description"])
    }
}

@Suite("MCP dispatch")
struct PlayToolDispatchTests {

    @Test("calling a write tool while gated off explains the gate rather than reporting it missing")
    func gatedWriteToolExplainsItself() async throws {
        do {
            _ = try await PlayTools.call(
                name: "play_halt_rollout",
                arguments: ["packageName": .string("com.example.app"), "track": .string("production")],
                writesEnabled: false,
                clientProvider: unusedClient
            )
            Issue.record("Expected the gated tool to throw")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("GOOGLE_PLAY_ENABLE_WRITES"))
        }
    }

    @Test("an unknown tool name is reported as unknown, not as gated")
    func unknownToolIsDistinctFromGated() async throws {
        do {
            _ = try await PlayTools.call(
                name: "play_does_not_exist",
                arguments: [:],
                writesEnabled: true,
                clientProvider: unusedClient
            )
            Issue.record("Expected an unknown-tool error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("Unknown tool"))
            #expect(!error.localizedDescription.contains("GOOGLE_PLAY_ENABLE_WRITES"))
        }
    }

    @Test("a missing required argument is reported before any client is built")
    func missingArgumentFailsFast() async throws {
        do {
            _ = try await PlayTools.call(
                name: "play_list_tracks",
                arguments: [:],
                writesEnabled: false,
                clientProvider: unusedClient
            )
            Issue.record("Expected a missing-argument error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("packageName"))
        }
    }
}

@Suite("Default package name")
struct DefaultPackageNameTests {

    @Test("the configured default fills in an omitted packageName")
    func defaultFillsIn() throws {
        let arguments = ToolArguments([:], defaultPackageName: "com.example.default")
        #expect(try arguments.packageName() == "com.example.default")
    }

    @Test("an explicit packageName wins over the default")
    func explicitWins() throws {
        let arguments = ToolArguments(["packageName": .string("com.example.other")], defaultPackageName: "com.example.default")
        #expect(try arguments.packageName() == "com.example.other")
    }

    @Test("with neither, the error names the environment variable that would fix it")
    func missingBothExplains() {
        do {
            _ = try ToolArguments([:]).packageName()
            Issue.record("Expected a missing packageName error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("GOOGLE_PLAY_PACKAGE_NAME"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("dispatch passes the default through to the handler")
    func dispatchUsesDefault() async throws {
        // The handler reaches for the client only after resolving the package name, so a
        // client-construction error proves the default satisfied the argument check.
        do {
            _ = try await PlayTools.call(
                name: "play_list_tracks",
                arguments: [:],
                writesEnabled: false,
                defaultPackageName: "com.example.default",
                clientProvider: unusedClient
            )
            Issue.record("Expected the stub client provider to throw")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("should not be constructed"))
        }
    }
}

@Suite("Tool argument decoding")
struct ToolArgumentDecodingTests {

    /// Decodes arguments from real JSON rather than hand-building `Value` cases — the encoding a
    /// host actually sends is exactly what the hand-built version failed to represent.
    private func arguments(_ json: String) throws -> ToolArguments {
        ToolArguments(try JSONDecoder().decode([String: Value].self, from: Data(json.utf8)))
    }

    @Test("an integral fraction sent as JSON 1.0 is read as a number, not reported missing")
    func integralDoubleIsRead() throws {
        // JSON 1.0 decodes to Value.int, so a doubleValue-only read reported "missing argument"
        // for a value that was supplied — hiding the real range error behind a wrong one.
        let args = try arguments(#"{"userFraction": 1.0}"#)

        #expect(try args.requireDouble("userFraction") == 1.0)
    }

    @Test("a plain integer is read as a number")
    func integerIsRead() throws {
        #expect(try arguments(#"{"userFraction": 0}"#).requireDouble("userFraction") == 0.0)
    }

    @Test("a fractional double is read as a number")
    func fractionalDoubleIsRead() throws {
        #expect(try arguments(#"{"userFraction": 0.25}"#).requireDouble("userFraction") == 0.25)
    }

    @Test("a stringified number is accepted, since some hosts send them that way")
    func stringifiedNumberIsRead() throws {
        #expect(try arguments(#"{"userFraction": "0.5"}"#).requireDouble("userFraction") == 0.5)
    }

    @Test("a genuinely absent argument is still reported missing")
    func absentArgumentThrows() throws {
        #expect(throws: GoogleAPIError.self) {
            _ = try arguments(#"{}"#).requireDouble("userFraction")
        }
    }

    @Test("a non-numeric value is rejected rather than silently coerced")
    func nonNumericThrows() throws {
        #expect(throws: GoogleAPIError.self) {
            _ = try arguments(#"{"userFraction": "not-a-number"}"#).requireDouble("userFraction")
        }
    }

    @Test("maxResults sent as a JSON double is still honoured")
    func integerArgumentAcceptsDouble() throws {
        #expect(try arguments(#"{"maxResults": 5.0}"#).int("maxResults", default: 50) == 5)
    }

    @Test("an optional number that is present but unparseable throws instead of reading as absent")
    func optionalDoubleIsStrict() throws {
        #expect(throws: GoogleAPIError.self) {
            _ = try arguments(#"{"userFraction": "10%"}"#).double("userFraction")
        }
        #expect(try arguments(#"{}"#).double("userFraction") == nil)
        #expect(try arguments(#"{"userFraction": null}"#).double("userFraction") == nil)
        #expect(try arguments(#"{"userFraction": ""}"#).double("userFraction") == nil)
        #expect(try arguments(#"{"userFraction": "0.1"}"#).double("userFraction") == 0.1)
    }

    @Test("optionalInt accepts whole numbers only")
    func optionalIntIsStrict() throws {
        #expect(try arguments(#"{"limit": 3}"#).optionalInt("limit") == 3)
        #expect(try arguments(#"{"limit": "4"}"#).optionalInt("limit") == 4)
        #expect(throws: GoogleAPIError.self) { _ = try arguments(#"{"limit": 2.5}"#).optionalInt("limit") }
    }

    @Test("booleans accept JSON booleans and their common string spellings")
    func booleanArguments() throws {
        #expect(try arguments(#"{"flag": true}"#).bool("flag") == true)
        #expect(try arguments(#"{"flag": "false"}"#).bool("flag") == false)
        #expect(try arguments(#"{}"#).bool("flag") == nil)
        #expect(throws: GoogleAPIError.self) { _ = try arguments(#"{"flag": "maybe"}"#).bool("flag") }
    }

    @Test("string lists accept arrays of strings or numbers, and comma-separated text")
    func stringListArguments() throws {
        #expect(try arguments(#"{"codes": ["412", 413]}"#).stringList("codes") == ["412", "413"])
        #expect(try arguments(#"{"codes": "412, 413"}"#).stringList("codes") == ["412", "413"])
        #expect(try arguments(#"{"codes": []}"#).stringList("codes") == nil)
        #expect(throws: GoogleAPIError.self) { _ = try arguments(#"{"codes": [true]}"#).stringList("codes") }
    }

    @Test("commit options default to errorIfInReview and parse the advertised values")
    func commitOptionArguments() throws {
        #expect(try arguments(#"{}"#).commitOptions() == GooglePlayCommitOptions(changesInReviewBehavior: .errorIfInReview))
        for raw in PlayTools.changesInReviewBehaviors {
            #expect(try arguments(#"{"changesInReviewBehavior": "\#(raw)"}"#).commitOptions().changesInReviewBehavior != nil)
        }
        #expect(
            try arguments(#"{"changesInReviewBehavior": "cancelInReviewAndSubmit"}"#).commitOptions()
                .changesInReviewBehavior == .cancelInReviewAndSubmit)
    }

    @Test("maxResults is clamped into range")
    func integerArgumentClamps() throws {
        #expect(try arguments(#"{"maxResults": 0}"#).int("maxResults", default: 50) == 1)
        #expect(try arguments(#"{"maxResults": 9999}"#).int("maxResults", default: 50) == 100)
    }
}

@Suite("Review filters")
struct ReviewFilterTests {

    private func review(stars: Int?, code: Int? = nil, replied: Bool = false) -> GooglePlayReview {
        var comments = [
            GooglePlayReviewComment(userComment: .init(text: "t", starRating: stars, appVersionCode: code))
        ]
        if replied { comments.append(GooglePlayReviewComment(developerComment: .init(text: "thanks"))) }
        return GooglePlayReview(reviewId: "r", comments: comments)
    }

    @Test("star, version, and reply filters each narrow the match")
    func filtersMatch() throws {
        let lowStars = try ReviewFilter(maxStars: 2)
        #expect(lowStars.matches(review(stars: 1)))
        #expect(!lowStars.matches(review(stars: 4)))
        #expect(!lowStars.matches(review(stars: nil)))

        let highStars = try ReviewFilter(minStars: 4)
        #expect(highStars.matches(review(stars: 5)))
        #expect(!highStars.matches(review(stars: nil)))

        let version = try ReviewFilter(appVersionCode: 412)
        #expect(version.matches(review(stars: 3, code: 412)))
        #expect(!version.matches(review(stars: 3, code: 411)))

        let unreplied = try ReviewFilter(unrepliedOnly: true)
        #expect(unreplied.matches(review(stars: 1)))
        #expect(!unreplied.matches(review(stars: 1, replied: true)))

        #expect(try ReviewFilter().isEmpty)
        #expect(!unreplied.isEmpty)
    }

    @Test("an impossible star range is rejected")
    func impossibleRange() {
        #expect(throws: GoogleAPIError.self) { _ = try ReviewFilter(minStars: 4, maxStars: 2) }
    }

    @Test("newest keeps the highest version codes in ascending order")
    func newestArtifacts() {
        #expect(PlayTools.newest([5, 1, 9, 3], limit: 2) { $0 } == [5, 9])
        #expect(PlayTools.newest([5, 1], limit: 5) { $0 } == [5, 1])
        #expect(PlayTools.newest([5, 1], limit: nil) { $0 } == [5, 1])
    }
}

@Suite("MCP rendering")
struct PlayToolRenderingTests {

    @Test("track rendering shows status, version codes, and rollout percentage")
    func rendersRolloutPercentage() {
        let tracks = [
            GooglePlayTrack(
                track: "production",
                releases: [
                    GooglePlayRelease(
                        name: "4.2.0",
                        versionCodes: ["412"],
                        status: .inProgress,
                        userFraction: 0.25,
                        releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Faster sync")]
                    )
                ])
        ]

        let output = PlayTools.render(tracks: tracks, packageName: "com.example.app")

        #expect(output.contains("production: inProgress"))
        #expect(output.contains("versionCodes=[412]"))
        #expect(output.contains("rollout=25%"))
        #expect(output.contains("[en-US] Faster sync"))
    }

    @Test("a track with no releases still appears")
    func rendersEmptyTrack() {
        let output = PlayTools.render(
            tracks: [GooglePlayTrack(track: "beta", releases: [])], packageName: "com.example.app")

        #expect(output.contains("beta: no releases"))
    }

    @Test("no tracks renders an explanatory line, not an empty string")
    func rendersNoTracks() {
        #expect(PlayTools.render(tracks: [], packageName: "com.example.app").contains("No tracks"))
    }

    @Test("review rendering shows stars, version, and any developer reply")
    func rendersReviews() {
        let reviews = [
            GooglePlayReview(
                reviewId: "r1",
                authorName: "Sam",
                comments: [
                    GooglePlayReviewComment(
                        userComment: .init(
                            text: "Crashes on launch", starRating: 1, device: "Pixel 8",
                            appVersionCode: 412, appVersionName: "4.2.0")),
                    GooglePlayReviewComment(developerComment: .init(text: "Fixed in 4.2.1")),
                ])
        ]

        let output = PlayTools.render(reviews: reviews, packageName: "com.example.app")

        #expect(output.contains("★"))
        #expect(output.contains("Sam"))
        #expect(output.contains("app 4.2.0"))
        #expect(output.contains("Crashes on launch"))
        #expect(output.contains("Fixed in 4.2.1"))
    }

    @Test("no reviews explains Google's one-week window rather than looking like a failure")
    func rendersNoReviews() {
        let output = PlayTools.render(reviews: [], packageName: "com.example.app")

        #expect(output.contains("last week"))
    }
}
