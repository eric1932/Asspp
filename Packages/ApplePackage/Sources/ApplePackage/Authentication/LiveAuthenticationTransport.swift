import AsyncHTTPClient
import Foundation
import NIOHTTP1

final class LiveAuthenticationTransport: AuthenticationTransport, @unchecked Sendable {
    private let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)

    func send(_ request: AuthenticationRequest) async throws -> AuthenticationResponse {
        try Task.checkCancellation()
        APLogger.logRequest(method: request.method, url: request.url.absoluteString, headers: request.headers)
        let outgoing = try HTTPClient.Request(
            url: request.url.absoluteString,
            method: .RAW(value: request.method),
            headers: HTTPHeaders(request.headers),
            body: request.body.map { .data($0) }
        )
        let task = client.execute(request: outgoing)
        let response = try await withTaskCancellationHandler {
            try await task.get()
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        APLogger.logResponse(status: response.status.code, headers: response.headers.map { ($0.name, $0.value) }, bodySize: response.body?.readableBytes)
        guard (response.body?.readableBytes ?? 0) <= 1_048_576 else { throw AuthenticationError.invalidResponse }
        let cookies = response.cookies.map { item in
            var cookie = Cookie(copyFrom: item)
            cookie.domain = (cookie.domain ?? request.url.host)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cookie
        }
        return AuthenticationResponse(
            status: Int(response.status.code),
            headers: response.headers.map { ($0.name, $0.value) },
            body: response.body.map { Data($0.readableBytesView) } ?? Data(),
            cookies: cookies
        )
    }

    func close() async {
        try? await client.shutdown()
    }
}
