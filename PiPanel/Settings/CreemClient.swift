import Foundation

/// Client model for Creem licenses. Every request goes through PiPanel's Cloudflare Worker so the
/// seller API key stays server-side and can be rotated without releasing a new app build.
///
/// Endpoint paths, request bodies, response shape, and error status codes below are confirmed
/// against docs.creem.io (not guessed). Two things remain genuinely unconfirmed without a live
/// account: (1) whether `instance` in the response is always an array (per one doc page's
/// example) or sometimes a single nullable object (per another page's OpenAPI schema) — handled
/// defensively below by decoding either shape; (2) the exact wording Creem uses for other 4xx/5xx
/// error bodies beyond the documented cases.
enum CreemClient {
    enum ClientError: Error {
        case invalidLicenseKey
        case activationLimitReached
        case licenseExpiredOrRevoked
        case alreadyDeactivated
        case invalidResponse
    }

    private static let baseURL = URL(string: "https://pipanel-license-server.lyle-xub.workers.dev/license")!

    struct LicenseResponse: Decodable {
        let status: String
        let key: String
        let activation: Int
        let activationLimit: Int?
        let instances: [Instance]

        struct Instance: Decodable, Identifiable, Equatable {
            let id: String
            let name: String?
            let status: String
        }

        private enum CodingKeys: String, CodingKey {
            case status, key, activation
            case activationLimit = "activation_limit"
            case instance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            key = try container.decode(String.self, forKey: .key)
            activation = try container.decode(Int.self, forKey: .activation)
            activationLimit = try container.decodeIfPresent(Int.self, forKey: .activationLimit)

            // Creem's docs disagree with themselves on whether `instance` is an array or a
            // single nullable object — accept either.
            if let array = try? container.decode([Instance].self, forKey: .instance) {
                instances = array
            } else if let single = try? container.decode(Instance.self, forKey: .instance) {
                instances = [single]
            } else {
                instances = []
            }
        }

        var valid: Bool { status == "active" }
    }

    static func activate(licenseKey: String, instanceName: String) async throws -> LicenseResponse {
        let response: LicenseResponse = try await post(
            path: "activate",
            body: ["key": licenseKey, "instance_name": instanceName],
            errorMap: [403: .activationLimitReached, 404: .invalidLicenseKey]
        )
        return response
    }

    static func validate(licenseKey: String, instanceId: String) async throws -> LicenseResponse {
        try await post(
            path: "validate",
            body: ["key": licenseKey, "instance_id": instanceId],
            errorMap: [404: .invalidLicenseKey, 410: .licenseExpiredOrRevoked]
        )
    }

    static func deactivate(licenseKey: String, instanceId: String) async throws -> LicenseResponse {
        try await post(
            path: "deactivate",
            body: ["key": licenseKey, "instance_id": instanceId],
            errorMap: [404: .invalidLicenseKey, 409: .alreadyDeactivated]
        )
    }

    private static func post(
        path: String,
        body: [String: String],
        errorMap: [Int: ClientError]
    ) async throws -> LicenseResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw errorMap[httpResponse.statusCode] ?? ClientError.invalidResponse
        }
        return try JSONDecoder().decode(LicenseResponse.self, from: data)
    }
}
