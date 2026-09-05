import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A canned HTTP response for ``MockURLProtocol``.
struct MockHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data

    static func json(_ json: String, statusCode: Int = 200) -> MockHTTPResponse {
        MockHTTPResponse(statusCode: statusCode, body: Data(json.utf8))
    }

    static func empty(statusCode: Int = 204) -> MockHTTPResponse {
        MockHTTPResponse(statusCode: statusCode, body: Data())
    }

    static func error(statusCode: Int, body: String = "") -> MockHTTPResponse {
        MockHTTPResponse(statusCode: statusCode, body: Data(body.utf8))
    }
}

/// One recorded request, so a test can assert on method and path as well as the response.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let query: String?
    let body: Data?
}

/// A `URLProtocol` that answers requests from a per-session handler.
///
/// Handlers are keyed by a session id carried in a request header, so suites running in
/// parallel cannot steal each other's responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> MockHTTPResponse

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let recorded = Mutex<[String: [RecordedRequest]]>([:])

    static let sessionHeader = "X-Mock-Session-ID"

    static func register(sessionID: String, handler: @escaping Handler) {
        handlers.withLock { $0[sessionID] = handler }
        recorded.withLock { $0[sessionID] = [] }
    }

    static func requests(for sessionID: String) -> [RecordedRequest] {
        recorded.withLock { $0[sessionID] ?? [] }
    }

    static func unregister(sessionID: String) {
        handlers.withLock { _ = $0.removeValue(forKey: sessionID) }
        recorded.withLock { _ = $0.removeValue(forKey: sessionID) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader),
            let handler = Self.handlers.withLock({ $0[sessionID] })
        else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockURLProtocol", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No handler registered for this session"]))
            return
        }

        // `httpBody` is nil once URLSession has turned the request into a stream, so read the
        // stream back when that happens — otherwise body assertions silently see nothing.
        let body =
            request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        Self.recorded.withLock {
            $0[sessionID, default: []].append(
                RecordedRequest(
                    method: request.httpMethod ?? "GET",
                    path: request.url?.path ?? "",
                    query: request.url?.query,
                    body: body
                ))
        }

        let mock = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Creates a `URLSession` whose requests are answered by `handler`, plus the session id needed
/// to read back the requests it recorded.
func makeMockSession(
    handler: @escaping MockURLProtocol.Handler
) -> (session: URLSession, sessionID: String) {
    let sessionID = UUID().uuidString
    MockURLProtocol.register(sessionID: sessionID, handler: handler)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    configuration.httpAdditionalHeaders = [MockURLProtocol.sessionHeader: sessionID]
    return (URLSession(configuration: configuration), sessionID)
}
