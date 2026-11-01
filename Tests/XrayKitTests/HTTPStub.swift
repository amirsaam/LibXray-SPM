import Foundation

// In-process HTTP stub: a session built by `HTTPStub.session()` routes every
// request through here, so downloader and feed tests run with no packets.
// Only URLs with a registered reply are intercepted; anything else fails
// closed instead of touching the wire.
final class HTTPStub: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    static var replies: [URL: Reply] = [:]

    /// Loopback URLs are ATS-exempt and never dialed — the stub intercepts first.
    static var stubIP: URL { URL(string: "http://127.0.0.1/geoip.dat")! }
    static var stubSite: URL { URL(string: "http://127.0.0.1/geosite.dat")! }
    static var stubFeed: URL { URL(string: "http://127.0.0.1/feed.txt")! }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.flatMap { replies[$0] } != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}
