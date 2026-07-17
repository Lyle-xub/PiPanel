import Foundation
import AppKit

/// Gates everything in GeneralSettingsView/AppearanceSettingsView except Launch at Login (the one
/// setting explicitly kept free) behind either a server-issued seven-day trial or a Creem license
/// key activated per-device. All Creem operations go through the Cloudflare Worker; no seller
/// credential is present in the app.
/// Gates the settings UI (FPS/appearance/panel placement customization, via MembershipGate) plus
/// one thing about PiP capture itself: PiPSessionManager.startSession caps a non-member at a
/// single concurrent PiP session (PiPSessionManager.Constants.freeSessionLimit) — a non-member can
/// still use PiPanel with its defaults on that one session, just can't run several at once or
/// customize FPS/appearance/panel placement.
///
/// Validation cadence: revalidates online at most once every 72 hours while a license is active,
/// checked opportunistically at launch, when Membership settings appear, and via a background
/// timer. If the Mac is offline when a check comes due, the last confirmed-valid state is trusted
/// for up to 14 days before the app locks itself out regardless of network reachability — this
/// bounds how long a revoked/refunded license can keep working on the honor system.
@MainActor
final class MembershipManager: ObservableObject {
    static let shared = MembershipManager()

    enum Entitlement: Equatable {
        case free
        case trial(expiresAt: Date)
        case licensed
    }

    @Published private(set) var entitlement: Entitlement = .free
    @Published private(set) var maskedLicenseKey: String?
    @Published private(set) var isValidating = false
    @Published private(set) var isCancellingTrial = false
    @Published var errorMessage: String?

    /// Every instance (device) currently activated on this license, as of the last successful
    /// online validate — refreshed as a side effect of revalidate(), same source DeviceManagementView
    /// lists from. Not persisted; a stale/empty list until the next successful validate is fine,
    /// since it's only ever shown live while that view is open (which itself forces a fresh check).
    @Published private(set) var instances: [CreemClient.LicenseResponse.Instance] = []
    @Published private(set) var activationCount = 0
    @Published private(set) var activationLimit: Int?
    @Published private(set) var devicesLastUpdatedAt: Date?
    @Published private(set) var isDeactivatingInstanceId: String?
    @Published private(set) var deviceManagementMessage: String?
    @Published private(set) var deviceManagementMessageIsError = false

    /// The instanceId *this* device registered under — used by DeviceManagementView to badge
    /// which row in the instances list is "this Mac" versus some other activated device.
    var ownInstanceId: String? { KeychainStore.get(forKey: KeychainKeys.instanceId) }

    @Published private(set) var isPurchasing = false
    @Published var purchaseStatusMessage: String?

    @Published private(set) var isRequestingRecovery = false
    @Published var recoveryStatusMessage: String?

    var isMember: Bool {
        switch entitlement {
        case .trial, .licensed: true
        case .free: false
        }
    }

    var isLicensed: Bool {
        if case .licensed = entitlement { return true }
        return false
    }

    var trialExpiresAt: Date? {
        if case .trial(let expiresAt) = entitlement { return expiresAt }
        return nil
    }

    var trialDaysRemaining: Int? {
        guard let expiresAt = trialExpiresAt else { return nil }
        return max(1, Int(ceil(expiresAt.timeIntervalSinceNow / (24 * 60 * 60))))
    }

    var isTrialCancelled: Bool {
        KeychainStore.get(forKey: KeychainKeys.trialCancelled) == "1"
    }

    private enum KeychainKeys {
        static let licenseKey = "membership.licenseKey"
        static let instanceId = "membership.instanceId"
        static let lastValidatedAt = "membership.lastValidatedAt"
        static let trialDeviceId = "trial.deviceId"
        static let trialExpiresAt = "trial.expiresAt"
        static let trialLastCheckedAt = "trial.lastCheckedAt"
        static let trialCancelled = "trial.cancelled"
    }

    private enum Constants {
        static let revalidationInterval: TimeInterval = 72 * 60 * 60
        static let maxOfflineGracePeriod: TimeInterval = 14 * 24 * 60 * 60
        static let trialRevalidationInterval: TimeInterval = 6 * 60 * 60
        static let trialOfflineGracePeriod: TimeInterval = 72 * 60 * 60
        static let backgroundCheckTickInterval: TimeInterval = 60 * 60
        static let purchasePollInterval: UInt64 = 3_000_000_000
        static let purchasePollTimeout: TimeInterval = 10 * 60
    }

    private var periodicTimer: Timer?

    #if DEBUG
    /// Dev-only: set PIPANEL_DEBUG_UNLOCK_MEMBERSHIP=1 to skip Creem entirely and treat every
    /// launch as a fully activated membership — for testing paid-gated settings (画面帧率/外观/
    /// 默认位置 in GeneralSettingsView/AppearanceSettingsView) without needing a real purchase or
    /// a Creem test-mode license. Same env-var-gated pattern as AppDelegate's
    /// PIPANEL_DEBUG_AUTOSTART; both are additionally wrapped in #if DEBUG so this makes it categorically
    /// unreachable in a Release build regardless of what env vars happen to be set, not just
    /// unreachable because nobody set the var.
    private static var isDebugUnlocked: Bool {
        ProcessInfo.processInfo.environment["PIPANEL_DEBUG_UNLOCK_MEMBERSHIP"] != nil
    }
    #endif

    private init() {
        #if DEBUG
        if Self.isDebugUnlocked {
            entitlement = .licensed
            maskedLicenseKey = "DEBUG-UNLOCKED"
            return
        }
        #endif
        _ = trialDeviceId
        if let key = KeychainStore.get(forKey: KeychainKeys.licenseKey) {
            maskedLicenseKey = Self.mask(key)
            Task { await revalidate() }
        } else {
            restoreCachedTrial()
            Task { await refreshTrial(force: true, startIfNeeded: true) }
        }
        startPeriodicRevalidation()
    }

    // MARK: - Activation

    func activate(licenseKey: String) async {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isValidating = true
        defer { isValidating = false }
        do {
            // A short stable suffix keeps two Macs with the same host name distinguishable in
            // device management and lets us identify the exact instance Creem just created.
            let instanceName = deviceActivationName
            let response = try await CreemClient.activate(licenseKey: trimmed, instanceName: instanceName)
            // Creem activation returns the instance it just created. The Worker may also expand
            // responses for compatibility, so still prefer the exact name we sent.
            let activatedInstance = response.instances.last(where: { $0.name == instanceName })
                ?? (response.instances.count == 1 ? response.instances.first : nil)
            guard let instanceId = activatedInstance?.id else {
                errorMessage = "激活失败，请检查激活码是否正确"
                return
            }
            KeychainStore.set(trimmed, forKey: KeychainKeys.licenseKey)
            KeychainStore.set(instanceId, forKey: KeychainKeys.instanceId)
            setLastValidated(Date())
            maskedLicenseKey = Self.mask(trimmed)
            entitlement = .licensed
            applyLicenseSnapshot(response)
            startPeriodicRevalidation()
        } catch CreemClient.ClientError.activationLimitReached {
            errorMessage = "这个激活码可激活的设备数量已用完，请在其他设备上取消激活，或购买更多设备的授权"
        } catch CreemClient.ClientError.invalidLicenseKey {
            errorMessage = "激活码无效，请检查是否输入正确"
        } catch CreemClient.ClientError.licenseExpiredOrRevoked {
            errorMessage = "授权已过期或被撤销（可能已退款），请重新购买"
        } catch {
            errorMessage = "网络请求失败，请检查网络连接后重试"
        }
    }

    /// The self-service "解绑" action — frees this device's activation slot so the same license
    /// key can be activated on a different Mac.
    @discardableResult
    func deactivate() async -> Bool {
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey),
              let instanceId = KeychainStore.get(forKey: KeychainKeys.instanceId) else {
            clearLicenseState()
            await refreshTrial(force: true, startIfNeeded: true)
            return true
        }

        errorMessage = nil
        isValidating = true
        defer { isValidating = false }
        do {
            _ = try await CreemClient.deactivate(licenseKey: key, instanceId: instanceId)
            clearLicenseState()
            await refreshTrial(force: true, startIfNeeded: true)
            return true
        } catch CreemClient.ClientError.alreadyDeactivated,
                CreemClient.ClientError.invalidLicenseKey {
            // The slot is already gone on the server, so local state should catch up.
            clearLicenseState()
            await refreshTrial(force: true, startIfNeeded: true)
            return true
        } catch {
            // Do not discard the local key on a transient failure: doing so would pretend the
            // server slot was freed even though it may still count against the activation limit.
            errorMessage = "取消激活失败，请检查网络连接后重试"
            return false
        }
    }

    /// DeviceManagementView's per-row "移除" action — deactivates *any* instance on this license,
    /// not just this device's own (that's deactivate() above). If the removed instance turns out to
    /// be this device's own (the user removed "this Mac" from the device list instead of using the
    /// dedicated 取消激活 button), clears local state the same way deactivate() does, since this
    /// device's activation is now gone either way. Re-validates afterward so `instances` reflects
    /// the removal immediately rather than waiting for the next 72h cycle.
    @discardableResult
    func deactivateInstance(_ instance: CreemClient.LicenseResponse.Instance) async -> Bool {
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey),
              isDeactivatingInstanceId == nil else { return false }
        clearDeviceManagementMessage()
        errorMessage = nil
        isDeactivatingInstanceId = instance.id
        defer { isDeactivatingInstanceId = nil }
        do {
            _ = try await CreemClient.deactivate(licenseKey: key, instanceId: instance.id)
            if instance.id == ownInstanceId {
                clearLicenseState()
                await refreshTrial(force: true, startIfNeeded: true)
            } else {
                // Creem's docs are inconsistent about whether a deactivate response contains the
                // whole instance array or only the affected instance. Validate once more so the
                // count and rows shown here always come from a complete snapshot.
                guard await refreshDevices(showSuccessMessage: false) else { return false }
                setDeviceManagementMessage("已移除“\(displayName(for: instance))”", isError: false)
            }
            return true
        } catch CreemClient.ClientError.alreadyDeactivated {
            if instance.id == ownInstanceId {
                clearLicenseState()
                await refreshTrial(force: true, startIfNeeded: true)
                return true
            }
            let refreshed = await refreshDevices(showSuccessMessage: false)
            if refreshed {
                setDeviceManagementMessage("这台设备已被移除，列表已刷新", isError: false)
            }
            return refreshed
        } catch CreemClient.ClientError.invalidLicenseKey {
            if instance.id == ownInstanceId {
                // A 404 for our own instance means it no longer occupies a server slot.
                clearLicenseState()
                await refreshTrial(force: true, startIfNeeded: true)
                return true
            }
            // A remote instance may have been removed from another Mac between loading this list
            // and pressing the button. If our own license still validates, treat that stale row as
            // already removed; otherwise revalidate will clear the invalid local entitlement.
            let refreshed = await refreshDevices(showSuccessMessage: false)
            if refreshed {
                setDeviceManagementMessage("这台设备已被移除，列表已刷新", isError: false)
            }
            return refreshed
        } catch {
            setDeviceManagementMessage("移除设备失败，请检查网络连接后重试", isError: true)
        }
        return false
    }

    /// Forces a live validation specifically for DeviceManagementView. Unlike the regular
    /// 72-hour background cadence this is always online, because the user expects the device
    /// count and remote-removal state to be current when they press refresh.
    @discardableResult
    func refreshDevices(showSuccessMessage: Bool = true) async -> Bool {
        clearDeviceManagementMessage()
        errorMessage = nil
        let refreshed = await revalidate(force: true)
        guard refreshed else {
            if isLicensed && errorMessage == nil {
                setDeviceManagementMessage("无法刷新设备列表，请检查网络连接后重试", isError: true)
            }
            return false
        }
        if showSuccessMessage {
            setDeviceManagementMessage("设备列表已更新", isError: false)
        }
        return true
    }

    func clearDeviceManagementMessage() {
        deviceManagementMessage = nil
        deviceManagementMessageIsError = false
    }

    // MARK: - Revalidation (72h cadence, 14-day offline grace)

    /// Called at launch, whenever the Membership settings page appears, and periodically from a
    /// background timer. Only actually calls Creem if 72 hours have passed since the last
    /// confirmed check (or `force` is set) — otherwise trusts the cached state, still bounded by
    /// the 14-day offline grace period.
    @discardableResult
    func revalidate(force: Bool = false) async -> Bool {
        #if DEBUG
        if Self.isDebugUnlocked { return true }
        #endif
        guard let key = KeychainStore.get(forKey: KeychainKeys.licenseKey),
              let instanceId = KeychainStore.get(forKey: KeychainKeys.instanceId) else {
            await refreshTrial(force: force, startIfNeeded: true)
            return false
        }

        if !force, let last = lastValidatedDate, Date().timeIntervalSince(last) < Constants.revalidationInterval {
            entitlement = isOfflineGraceExpired(since: last) ? .free : .licensed
            return entitlement == .licensed
        }

        isValidating = true
        defer { isValidating = false }
        do {
            let response = try await CreemClient.validate(licenseKey: key, instanceId: instanceId)
            entitlement = response.valid ? .licensed : .free
            applyLicenseSnapshot(response)
            if response.valid {
                setLastValidated(Date())
            } else {
                errorMessage = "专业版授权已失效（可能已退款或取消），请重新激活"
            }
            return response.valid
        } catch CreemClient.ClientError.invalidLicenseKey {
            // The key or this device's instance was explicitly removed server-side (e.g. via
            // "设备管理" on another device, or a support action) — this is a definitive answer,
            // not a network hiccup, so it doesn't get the offline grace period.
            clearLicenseState()
            errorMessage = "这台设备的授权已被移除，请重新激活"
            await refreshTrial(force: true, startIfNeeded: true)
            return false
        } catch CreemClient.ClientError.licenseExpiredOrRevoked {
            clearLicenseState()
            errorMessage = "专业版授权已失效（可能已退款或取消），请重新激活"
            await refreshTrial(force: true, startIfNeeded: true)
            return false
        } catch {
            // Network unreachable at the moment a check was due — fall back to the offline grace
            // period instead of an immediate lockout. A license that's never been validated
            // online at all doesn't get the benefit of the doubt.
            if let last = lastValidatedDate {
                entitlement = isOfflineGraceExpired(since: last) ? .free : .licensed
                if !isMember {
                    errorMessage = "已超过 14 天未能连网验证授权，请连接网络后重试"
                }
            } else {
                entitlement = .free
            }
            return false
        }
    }

    // MARK: - Seven-day Pro trial

    /// Starts the trial exactly once on the server, then refreshes it against server time. The
    /// Keychain device id normally survives app deletion, while the permanent KV record prevents
    /// the same id from receiving another trial after expiry.
    func refreshTrial(force: Bool = false, startIfNeeded: Bool = true) async {
        guard KeychainStore.get(forKey: KeychainKeys.licenseKey) == nil else { return }
        guard !isTrialCancelled else {
            entitlement = .free
            return
        }

        if !force,
           let lastChecked = trialLastCheckedDate,
           Date().timeIntervalSince(lastChecked) < Constants.trialRevalidationInterval {
            restoreCachedTrial()
            return
        }

        isValidating = true
        defer { isValidating = false }
        do {
            let response = if startIfNeeded {
                try await LicenseServerClient.startTrial(deviceId: trialDeviceId)
            } else {
                try await LicenseServerClient.trialStatus(deviceId: trialDeviceId)
            }
            applyTrialResponse(response)
        } catch {
            restoreCachedTrial()
        }
    }

    private func applyTrialResponse(_ response: LicenseServerClient.TrialResponse) {
        setTrialLastChecked(Date())
        if response.status == .cancelled {
            KeychainStore.set("1", forKey: KeychainKeys.trialCancelled)
        }
        if response.status == .trial, let expiresAt = response.expiresAt {
            KeychainStore.set(Self.iso8601.string(from: expiresAt), forKey: KeychainKeys.trialExpiresAt)
        } else {
            // A cancelled trial can still have a future expiresAt on the permanent server record.
            // Leaving that timestamp cached would let restoreCachedTrial unlock Pro again while
            // offline, so every non-trial response must remove the cached active entitlement.
            KeychainStore.delete(forKey: KeychainKeys.trialExpiresAt)
        }
        if response.status == .trial, !isTrialCancelled,
           let expiresAt = response.expiresAt, expiresAt > response.serverTime {
            entitlement = .trial(expiresAt: expiresAt)
        } else {
            entitlement = .free
        }
    }

    /// Immediately and permanently ends this installation's server-issued trial. The server keeps
    /// the original record and adds cancelledAt, so this cannot be used to restart the seven-day
    /// period. Local entitlement is changed only after the server confirms cancellation; a failed
    /// request leaves the still-valid trial usable and surfaces a retryable error in Settings.
    func cancelTrial() async {
        guard trialExpiresAt != nil, !isCancellingTrial else { return }
        errorMessage = nil
        isCancellingTrial = true
        defer { isCancellingTrial = false }

        do {
            let response = try await LicenseServerClient.cancelTrial(deviceId: trialDeviceId)
            guard response.status == .cancelled else {
                errorMessage = "取消试用失败，请稍后重试"
                return
            }
            applyTrialResponse(response)
        } catch {
            errorMessage = "取消试用失败，请检查网络连接后重试"
        }
    }

    private func restoreCachedTrial() {
        guard !isTrialCancelled,
              let expiresRaw = KeychainStore.get(forKey: KeychainKeys.trialExpiresAt),
              let expiresAt = Self.iso8601.date(from: expiresRaw),
              let lastChecked = trialLastCheckedDate,
              expiresAt > Date(),
              Date().timeIntervalSince(lastChecked) <= Constants.trialOfflineGracePeriod else {
            entitlement = .free
            return
        }
        entitlement = .trial(expiresAt: expiresAt)
    }

    private func startPeriodicRevalidation() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Constants.backgroundCheckTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.revalidate() }
        }
    }

    private func isOfflineGraceExpired(since last: Date) -> Bool {
        Date().timeIntervalSince(last) > Constants.maxOfflineGracePeriod
    }

    private var lastValidatedDate: Date? {
        guard let raw = KeychainStore.get(forKey: KeychainKeys.lastValidatedAt) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func setLastValidated(_ date: Date) {
        KeychainStore.set(ISO8601DateFormatter().string(from: date), forKey: KeychainKeys.lastValidatedAt)
    }

    // MARK: - Purchase (App → Worker → Creem Checkout → auto-claim)

    /// Creates a Creem Checkout session for the given tier via the licensing worker, opens it in
    /// the default browser, then polls the worker for up to ~10 minutes waiting for Creem's
    /// webhook to fulfil the purchase — once it does, activates the returned license on this
    /// device automatically, no copy-pasting required. The license is also emailed as a fallback
    /// (see Server/cloudflare-worker).
    func purchase(tier: PurchaseTier) async {
        errorMessage = nil
        purchaseStatusMessage = "正在打开付款页面…"
        isPurchasing = true
        defer { isPurchasing = false }

        let claimToken = UUID().uuidString
        do {
            let session = try await LicenseServerClient.createCheckoutSession(tier: tier, claimToken: claimToken)
            NSWorkspace.shared.open(session.url)
            purchaseStatusMessage = "请在浏览器中完成付款，完成后这里会自动激活…"
            await pollForClaim(token: claimToken)
        } catch {
            purchaseStatusMessage = nil
            errorMessage = "创建付款会话失败，请检查网络连接后重试"
        }
    }

    private func pollForClaim(token: String) async {
        let deadline = Date().addingTimeInterval(Constants.purchasePollTimeout)
        while Date() < deadline {
            if let status = try? await LicenseServerClient.pollClaim(token: token),
               case .ready(let licenseKey) = status {
                purchaseStatusMessage = nil
                await activate(licenseKey: licenseKey)
                return
            }
            try? await Task.sleep(nanoseconds: Constants.purchasePollInterval)
        }
        purchaseStatusMessage = "还没检测到付款完成。如果已经完成付款，稍后会自动激活；也可以直接用邮件里的授权码手动激活。"
    }

    // MARK: - Recovery (purchase email → one-time link)

    /// Requests a one-time recovery link be emailed to `email`, if it has a license on file.
    func requestRecovery(email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRequestingRecovery = true
        defer { isRequestingRecovery = false }
        do {
            try await LicenseServerClient.requestRecovery(email: trimmed)
            recoveryStatusMessage = "如果这个邮箱有购买记录，恢复邮件已经发出，请在这台 Mac 上查收并点击链接。"
        } catch {
            recoveryStatusMessage = "请求失败，请检查网络连接后重试"
        }
    }

    /// Called by AppDelegate when the app is opened via a "pipanel://recover?token=..." link from
    /// the recovery email — redeems the token for the real license key and activates it.
    func handleRecoveryDeepLink(token: String) async {
        errorMessage = nil
        do {
            let licenseKey = try await LicenseServerClient.confirmRecovery(token: token)
            await activate(licenseKey: licenseKey)
        } catch {
            errorMessage = "恢复链接无效或已过期，请重新申请"
        }
    }

    // MARK: - Local state

    private func clearLicenseState() {
        KeychainStore.delete(forKey: KeychainKeys.licenseKey)
        KeychainStore.delete(forKey: KeychainKeys.instanceId)
        KeychainStore.delete(forKey: KeychainKeys.lastValidatedAt)
        maskedLicenseKey = nil
        entitlement = .free
        instances = []
        activationCount = 0
        activationLimit = nil
        devicesLastUpdatedAt = nil
    }

    private func applyLicenseSnapshot(_ response: CreemClient.LicenseResponse) {
        instances = response.instances
        activationCount = response.activation
        activationLimit = response.activationLimit
        devicesLastUpdatedAt = Date()
    }

    private func setDeviceManagementMessage(_ message: String, isError: Bool) {
        deviceManagementMessage = message
        deviceManagementMessageIsError = isError
    }

    private func displayName(for instance: CreemClient.LicenseResponse.Instance) -> String {
        let name = instance.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "未命名设备" : name
    }

    private var deviceActivationName: String {
        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let readableName = hostName.isEmpty ? "Mac" : hostName
        let suffix = trialDeviceId.replacingOccurrences(of: "-", with: "").suffix(4).uppercased()
        let reservedSuffixLength = suffix.count + 3 // " · "
        let prefix = String(readableName.prefix(max(1, 80 - reservedSuffixLength)))
        return "\(prefix) · \(suffix)"
    }

    private var trialDeviceId: String {
        if let existing = KeychainStore.get(forKey: KeychainKeys.trialDeviceId) { return existing }
        let created = UUID().uuidString
        KeychainStore.set(created, forKey: KeychainKeys.trialDeviceId)
        return created
    }

    private var trialLastCheckedDate: Date? {
        guard let raw = KeychainStore.get(forKey: KeychainKeys.trialLastCheckedAt) else { return nil }
        return Self.iso8601.date(from: raw)
    }

    private func setTrialLastChecked(_ date: Date) {
        KeychainStore.set(Self.iso8601.string(from: date), forKey: KeychainKeys.trialLastCheckedAt)
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static func mask(_ key: String) -> String {
        guard key.count > 4 else { return key }
        return String(repeating: "•", count: key.count - 4) + key.suffix(4)
    }
}
