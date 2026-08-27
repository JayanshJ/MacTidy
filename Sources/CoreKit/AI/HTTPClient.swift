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

        /// Truncated UTF-8 body for diagnostics. Shown to the user when a 2xx
        /// response has no parseable model reply, so "Reachable but no model
        /// reply" is no longer a blind failure — they can see whether the
        /// server returned an error JSON, a differently-shaped reply, or an
        /// empty body. Capped so a huge or binary body can't flood the UI.
        public func bodySnippet(maxLength: Int = 300) -> String {
            let s = string()
            if s.isEmpty { return "(empty body)" }
            if s.count > maxLength { return String(s.prefix(maxLength)) + "…" }
            return s
        }
    }

    public enum HTTPError: Error, LocalizedError {
        case badURL(String)
        case requestFailed(Int, String)
        case timeout
        /// No network route to the endpoint — host not found, connection
        /// refused, offline, or the request was cancelled. Distinct from
        /// `.timeout` (which means the endpoint was reachable but slow) so
        /// the UI can tell the user the right thing: "is the endpoint up?"
        /// vs "the model is slow / the timeout is too low".
        case connection(String)
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .badURL(let u): "Bad URL: \(u)"
            case .requestFailed(let code, let body): "Request failed (\(code)): \(body)"
            case .timeout: "The request timed out."
            case .connection(let m): "Couldn't reach the endpoint: \(m)"
            case .decoding(let m): "Failed to decode the model response: \(m)"
            }
        }
    }

    /// Maps a thrown `URLError` to the right `HTTPError`. Only true timeouts
    /// (`.timedOut`) and mid-stream disconnects (`.networkConnectionLost`)
    /// become `.timeout`; everything else a user would blame on the endpoint
    /// being down (`.notConnectedToInternet`, `.cannotFindHost`,
    /// `.cannotConnectToHost`, `.cancelled`, …) becomes `.connection`. The
    /// previous code collapsed *all* `URLError`s into `.timeout`, so a
    /// refused connection printed "The request timed out" — misleading.
    private static func map(_ error: URLError) -> HTTPError {
        switch error.code {
        case .timedOut, .networkConnectionLost:
            return .timeout
        case .cancelled:
            return .connection("request cancelled")
        case .notConnectedToInternet:
            return .connection("no internet connection")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff:
            return .connection(error.localizedDescription)
        default:
            return .connection(error.localizedDescription)
        }
    }

    @discardableResult
    public static func post(
        url: String,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 60
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
        } catch let error as URLError {
            throw map(error)
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

    /// GET a JSON endpoint. Used for Ollama's `/api/tags` — read-only model
    /// discovery, no credentials. Short timeout so detection fails fast when
    /// Ollama isn't running.
    @discardableResult
    public static func get(
        url: String,
        timeout: TimeInterval = 3
    ) async throws -> Response {
        guard let endpoint = URL(string: url) else { throw HTTPError.badURL(url) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw map(error)
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