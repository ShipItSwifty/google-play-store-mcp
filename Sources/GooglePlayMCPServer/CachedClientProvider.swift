import GooglePlayKit
import Synchronization

/// Resolves the ``GooglePlayClient`` once and reuses it for every later tool call.
///
/// The client owns the JWT generator, and the generator owns the OAuth2 token cache. Building a
/// fresh client per call threw that cache away, so every tool call paid for an RSA signature and
/// a round trip to Google's token endpoint before doing any work. Reusing the client lets a token
/// serve every call until it is within a minute of expiry.
///
/// Only a *successful* resolution is memoized: a credential problem is still reported per call,
/// and once the user fixes the file the next call picks it up without restarting the server.
final class CachedClientProvider: Sendable {
    private let make: PlayTools.ClientProvider
    private let cached = Mutex<GooglePlayClient?>(nil)

    init(_ make: @escaping PlayTools.ClientProvider) {
        self.make = make
    }

    /// The memoized client, resolving it on first use.
    func client() throws -> GooglePlayClient {
        try cached.withLock { slot in
            if let existing = slot { return existing }
            let client = try make()
            slot = client
            return client
        }
    }
}
