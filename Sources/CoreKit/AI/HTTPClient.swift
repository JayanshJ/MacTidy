import Foundation

/// Minimal URLSession-based JSON HTTP helper shared by the provider advisors.
/// No third-party dependencies — just `URLSession` + `JSONSerialization`. All
/// network calls time out via a configurable `timeout` so the UI can fall
/// back to the deterministic ranking instead of hanging.
public enum HTTPClient {
    public struct Response: Sendable {
        public let statusCode: Int
        public let body: Data
        public var json: Any? {
            try? JSONSerialization.jsonObject(with: body)
        }
        public func string() -> String { String(data: body, encoding: .utf8) ?? "" }
    }

    public enum HTTPError: Error, LocalizedError {
        case badURL(String)
        case requestFailed(Int, String)
        case timeout
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .badURL(let u): "Bad URL: \(u)"
            case .requestFailed(let code, let body): "Request failed (\(code)): \(body)"
            case .timeout: "The request timed out."
            case .decoding(let m): "Failed to decode the model response: \(m)"
            }
        }
    }

    @discardableResult
    public static func post(
        url: String,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 20
    ) async throws -> Response {
        guard let endpoint = URL(string: url) else { throw HTTPError.badURL(url) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw HTTPError.timeout
        } catch {
            throw HTTPError.requestFailed(0, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.requestFailed(0, "no http response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return Response(statusCode: http.statusCode, body: data)
    }
}