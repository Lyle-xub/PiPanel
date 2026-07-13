import Foundation

/// Thin wrapper around Creem's License API (https://docs.creem.io/learn/license-keys/license-keys).
/// Chosen over LemonSqueezy specifically because LemonSqueezy's checkout/payments aren't usable
/// from mainland China — Creem is a Merchant of Record aimed at indie/SaaS sellers with broader
/// regional payment support.
///
/// Unlike LemonSqueezy's license endpoints (public/keyless — the license key itself was the only
/// credential needed), Creem's require an API key identifying the *seller* account, sent as the
/// `x-api-key` header on every call. This key only grants license validate/activate/deactivate
/// for this seller's own products, not general account access, so it's the intended thing to ship
/// inside a client app (same tradeoff as e.g. a Stripe *publishable* key, not a secret key) — but
/// it still needs to be replaced with a real value below before this compiles into something
/// useful, and API field names should be double-checked against Creem's current docs/a real
/// purchase once a product exists, since this was written without a live account to test against.
enum CreemClient {
    enum ClientError: Error {
        case invalidResponse
    }

    /// TODO: replace with the real API key from the Creem dashboard (Developers → API Keys).
    private static let apiKey = "YOUR_CREEM_API_KEY"

    private static let baseURL = URL(string: "https://api.creem.io/v1/licenses")!

    struct ActivateResponse: Decodable {
        let status: String
        let instance: Instance?

        struct Instance: Decodable {
            let id: String
        }

        var activated: Bool { status == "active" }
    }

    struct ValidateResponse: Decodable {
        let status: String

        var valid: Bool { status == "active" }
    }

    static func activate(licenseKey: String, instanceName: String) async throws -> ActivateResponse {
        try await post(path: "activate", body: ["key": licenseKey, "instance_name": instanceName])
    }

    static func validate(licenseKey: String, instanceId: String) async throws -> ValidateResponse {
        try await post(path: "validate", body: ["key": licenseKey, "instance_id": instanceId])
    }

    static func deactivate(licenseKey: String, instanceId: String) async throws -> ValidateResponse {
        try await post(path: "deactivate", body: ["key": licenseKey, "instance_id": instanceId])
    }

    private static func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<500).contains(httpResponse.statusCode) else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
