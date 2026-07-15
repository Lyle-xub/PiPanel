import Foundation

/// Talks to PiPanel's Cloudflare Worker for purchases, recovery, and server-authoritative trials.
/// The app carries no seller credential; Creem license operations are also proxied by the worker
/// through `CreemClient`.
enum LicenseServerClient {
    enum ClientError: Error {
        case invalidResponse
    }

    private static let baseURL = URL(string: "https://pipanel-license-server.lyle-xub.workers.dev")!

    struct CheckoutSession: Decodable {
        let url: URL
    }

    enum ClaimStatus {
        case pending
        case ready(licenseKey: String)
    }

    struct TrialResponse: Decodable {
        enum Status: String, Decodable {
            case trial
            case expired
            case cancelled
            case notStarted = "not_started"
        }

        let status: Status
        let startedAt: Date?
        let expiresAt: Date?
        let cancelledAt: Date?
        let serverTime: Date
    }

    static func startTrial(deviceId: String) async throws -> TrialResponse {
        try await trialRequest(path: "trial/start", deviceId: deviceId)
    }

    static func trialStatus(deviceId: String) async throws -> TrialResponse {
        try await trialRequest(path: "trial/status", deviceId: deviceId)
    }

    static func cancelTrial(deviceId: String) async throws -> TrialResponse {
        try await trialRequest(path: "trial/cancel", deviceId: deviceId)
    }

    private static func trialRequest(path: String, deviceId: String) async throws -> TrialResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrialResponse.self, from: data)
    }

    /// Starts a Creem Checkout session for the given device tier. The app opens the returned URL
    /// in the default browser; the worker fulfils the purchase asynchronously via Creem's
    /// webhook, which `pollClaim` then picks up.
    static func createCheckoutSession(tier: PurchaseTier, claimToken: String) async throws -> CheckoutSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("create-checkout-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tier": tier.rawValue,
            "claimToken": claimToken
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(CheckoutSession.self, from: data)
    }

    /// Checks whether the checkout for `token` has been fulfilled yet. Single-use server-side —
    /// once this returns `.ready`, the token is consumed and won't return the key again.
    static func pollClaim(token: String) async throws -> ClaimStatus {
        var components = URLComponents(url: baseURL.appendingPathComponent("claim"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if http.statusCode == 202 { return .pending }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.invalidResponse }

        struct Response: Decodable { let status: String; let licenseKey: String? }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == "ready", let key = decoded.licenseKey else { return .pending }
        return .ready(licenseKey: key)
    }

    /// Asks the worker to email a one-time recovery link to `email` if it has a license on file.
    /// Always succeeds from the caller's point of view (the worker intentionally doesn't reveal
    /// whether the email matched anything, to avoid leaking which addresses have purchased).
    static func requestRecovery(email: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("recover/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
    }

    /// Redeems the one-time token from a "pipanel://recover?token=..." deep link for the actual
    /// license key. Single-use server-side.
    static func confirmRecovery(token: String) async throws -> String {
        var components = URLComponents(url: baseURL.appendingPathComponent("recover/confirm"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
        struct Response: Decodable { let licenseKey: String }
        return try JSONDecoder().decode(Response.self, from: data).licenseKey
    }
}
