import Foundation

/// Client model for Creem licenses. Every request goes through PiPanel's Cloudflare Worker so the
/// seller API key stays server-side and can be rotated without releasing a new app build.
///
/// Endpoint paths, request bodies, response shape, and error status codes below are confirmed
/// against docs.creem.io. Creem returns the one instance involved in an activate/validate request;
/// PiPanel's Worker deliberately expands successful validation responses to an array containing
/// every tracked active instance so device management can show the same devices counted by
/// `activation`. Decoding both shapes keeps activation responses and older Worker deployments
/// compatible.
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

            // Creem returns a single object; PiPanel's validation proxy expands it to an array.
            // Accept both so activation and validation share one model.
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
