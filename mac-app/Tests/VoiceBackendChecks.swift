import Foundation

final class BackendStub: URLProtocol {
    static var responseBody = #"{"reply":"Hello wave"}"#
    static var statusCode = 200
    static var unreachable = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.absoluteString == "http://127.0.0.1:4000/ask")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        if Self.unreachable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct BackendChecks {
    static func main() async throws {
        let reply = try await backend().ask("hello wave")
        precondition(reply == "Hello wave")
        BackendStub.responseBody = "not JSON"
        await expectFailure("Backend returned an invalid reply")
        BackendStub.responseBody = #"{"reply":""}"#
        await expectFailure("Backend returned an invalid reply")
        BackendStub.statusCode = 503
        await expectFailure("Backend returned an invalid reply")
        BackendStub.unreachable = true
        await expectFailure("Backend not reachable")
        print("PASS: reply decoding, invalid JSON, empty reply, HTTP error, backend unreachable")
    }
    static func backend() -> VoiceBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendStub.self]
        return VoiceBackend(configuration: config)
    }
    static func expectFailure(_ message: String) async {
        do {
            _ = try await backend().ask("hello wave")
            preconditionFailure("Expected failure")
        } catch { precondition(error.localizedDescription == message) }
    }
}
