import Foundation
import AppKit

/// Gates everything in GeneralSettingsView/AppearanceSettingsView except Launch at Login (the one
/// setting explicitly kept free) behind a Creem license key (see CreemClient's doc comment for
/// why Creem rather than LemonSqueezy — LemonSqueezy's checkout isn't usable from mainland China).
/// Deliberately gates the *settings UI* only, not PiP capture itself — a non-member can still use
/// PiPanel with its defaults, just can't customize FPS/appearance/panel placement.
@MainActor
final class MembershipManager: ObservableObject {
    static let shared = MembershipManager()

    @Published private(set) var isMember = false
    @Published private(set) var maskedLicenseKey: String?
    @Published private(set) var isValidating = false
    @Published var errorMessage: String?

    private enum KeychainKeys {
        static let licenseKey = "membership.licenseKey"
        static let instanceId = "membership.instanceId"
    }

    /// TODO: replace with the real checkout link once the Creem product exists —
    /// Creem dashboard → Products → (product) → "Copy checkout link".
    static let purchaseURL = URL(string: "https://creem.io/payment/YOUR-PRODUCT-ID")!

    private init() {
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey) else { return }
        maskedLicenseKey = Self.mask(key)
        Task { await revalidate() }
    }

    func activate(licenseKey: String) async {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isValidating = true
        defer { isValidating = false }
        do {
            let instanceName = ProcessInfo.processInfo.hostName
            let response = try await CreemClient.activate(licenseKey: trimmed, instanceName: instanceName)
            guard response.activated, let instanceId = response.instance?.id else {
                errorMessage = "激活失败，请检查激活码是否正确"
                return
            }
            KeychainStore.set(trimmed, forKey: KeychainKeys.licenseKey)
            KeychainStore.set(instanceId, forKey: KeychainKeys.instanceId)
            maskedLicenseKey = Self.mask(trimmed)
            isMember = true
        } catch {
            errorMessage = "网络请求失败，请检查网络连接后重试"
        }
    }

    func deactivate() async {
        defer { clearLocalState() }
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey),
              let instanceId = KeychainStore.get(forKey: KeychainKeys.instanceId) else { return }
        isValidating = true
        defer { isValidating = false }
        // Best-effort — even if this fails (offline, etc.), the local state still clears, since
        // the user's intent ("stop using this activation on this Mac") is a local fact regardless
        // of whether the server-side instance record gets cleaned up right now.
        _ = try? await CreemClient.deactivate(licenseKey: key, instanceId: instanceId)
    }

    /// Called at launch (if a key is already stored) and whenever the Membership settings page
    /// appears, to catch refunds/cancellations rather than trusting a stale "activated once"
    /// local flag forever.
    func revalidate() async {
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey),
              let instanceId = KeychainStore.get(forKey: KeychainKeys.instanceId) else {
            isMember = false
            return
        }
        isValidating = true
        defer { isValidating = false }
        do {
            let response = try await CreemClient.validate(licenseKey: key, instanceId: instanceId)
            isMember = response.valid
            if !response.valid {
                errorMessage = "会员已失效（可能已退款或取消），请重新激活"
            }
        } catch {
            // A network failure shouldn't immediately lock out an already-activated member —
            // keep whatever isMember already was and just retry next time this is called.
        }
    }

    private func clearLocalState() {
        KeychainStore.delete(forKey: KeychainKeys.licenseKey)
        KeychainStore.delete(forKey: KeychainKeys.instanceId)
        maskedLicenseKey = nil
        isMember = false
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 4 else { return key }
        return String(repeating: "•", count: key.count - 4) + key.suffix(4)
    }
}
