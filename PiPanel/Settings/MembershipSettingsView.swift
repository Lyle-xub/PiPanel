import SwiftUI

struct MembershipSettingsView: View {
    @ObservedObject private var membership = MembershipManager.shared
    @State private var showLicenseSheet = false
    @State private var showDeviceManagement = false
    @State private var showCancelTrialConfirmation = false
    @State private var showDeactivateConfirmation = false

    /// Purchasing now happens entirely on the marketing site rather than via an in-app Creem
    /// Checkout flow (see 购买专业版 below) — pipanel.app is the one place price/tiers/payment
    /// methods are shown, so this view doesn't need to duplicate any of that.
    private static let purchaseURL = URL(string: "https://pipanel.app")!

    var body: some View {
        // Plain ScrollView, not a Form — see MembershipSettingsView's own `card` doc comment for
        // why this stays a hand-styled status panel rather than a Form/Section settings list.
        // Needs to scroll on its own now that SettingsRootView no longer wraps every section in a
        // single shared ScrollView.
        ScrollView {
            VStack(spacing: 16) {
                statusHeader

                if membership.isLicensed {
                    activatedCard
                } else if membership.trialExpiresAt != nil {
                    trialCard
                } else {
                    notActivatedCard
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task {
            await membership.revalidate()
        }
        .sheet(isPresented: $showLicenseSheet) {
            LicenseActivationSheetView()
        }
        .sheet(isPresented: $showDeviceManagement) {
            DeviceManagementView()
        }
        .alert("取消专业版试用？", isPresented: $showCancelTrialConfirmation) {
            Button("保留试用", role: .cancel) {}
            Button("取消试用", role: .destructive) {
                Task { await membership.cancelTrial() }
            }
        } message: {
            Text("取消后将立即失去专业版功能，且这台设备无法重新开始 7 天试用。此操作不可撤销。")
        }
        .alert("取消激活这台 Mac？", isPresented: $showDeactivateConfirmation) {
            Button("保留激活", role: .cancel) {}
            Button("取消激活", role: .destructive) {
                Task { await membership.deactivate() }
            }
        } message: {
            Text("这台 Mac 将立即失去专业版权限，并释放一个设备名额。之后仍可使用同一个许可证重新激活。")
        }
    }

    // MARK: - Header (icon + title, matching a licensing status page's usual "big badge + verdict"
    // layout — the badge itself carries the granted/not-granted read at a glance before anyone
    // reads a word of the card below it).

    private var statusHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 56))
                .foregroundStyle(statusColor)
            Text(statusTitle)
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(.top, 8)
    }

    private var statusIcon: String {
        if membership.isLicensed { return "checkmark.seal.fill" }
        if membership.trialExpiresAt != nil { return "clock.badge.checkmark.fill" }
        if membership.isTrialCancelled { return "xmark.circle.fill" }
        return "star.circle.fill"
    }

    private var statusTitle: String {
        if membership.isLicensed { return "专业版已激活" }
        if membership.trialExpiresAt != nil { return "正在试用专业版" }
        if membership.isTrialCancelled { return "专业版试用已取消" }
        return "专业版试用已结束"
    }

    private var statusColor: Color {
        if membership.isLicensed { return .green }
        if membership.isTrialCancelled { return .secondary }
        return SettingsTheme.accent
    }

    // MARK: - Activated

    private var activatedCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if let masked = membership.maskedLicenseKey {
                    labeledRow(label: "激活码", value: masked)
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(SettingsTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设备管理")
                            .font(.system(size: 12, weight: .medium))
                        Text("查看已激活设备，或远程释放旧设备名额")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if membership.activationCount > 0 {
                        Text(deviceUsageText)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SettingsTheme.accent.opacity(0.09), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Button("管理设备") {
                        showDeviceManagement = true
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("取消激活", role: .destructive) {
                        showDeactivateConfirmation = true
                    }
                    .buttonStyle(PillButtonStyle(tint: .red))
                    .disabled(membership.isValidating)
                }
                if let error = membership.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var deviceUsageText: String {
        if let limit = membership.activationLimit {
            return "\(membership.activationCount) / \(limit)"
        }
        return "\(membership.activationCount) 台"
    }

    // MARK: - Trial

    private var trialCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("7 天专业版试用")
                            .font(.system(size: 13, weight: .semibold))
                        if let days = membership.trialDaysRemaining {
                            Text("剩余 \(days) 天，期间可使用全部专业功能")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let expiresAt = membership.trialExpiresAt {
                        Text(expiresAt, style: .date)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Button("购买专业版") {
                        NSWorkspace.shared.open(Self.purchaseURL)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("已有许可证？") {
                        showLicenseSheet = true
                    }
                    .buttonStyle(PillButtonStyle(tint: .gray))
                    Spacer()
                    Button {
                        showCancelTrialConfirmation = true
                    } label: {
                        HStack(spacing: 5) {
                            if membership.isCancellingTrial {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(membership.isCancellingTrial ? "正在取消…" : "取消试用")
                        }
                    }
                    .buttonStyle(PillButtonStyle(tint: .red))
                    .disabled(membership.isCancellingTrial || membership.isValidating)
                }
                if let error = membership.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Not activated

    private var notActivatedCard: some View {
        card {
            VStack(spacing: 0) {
                labeledRow(
                    label: "状态",
                    value: membership.isTrialCancelled ? "7 天试用已取消" : "7 天试用已结束"
                )
                Divider().padding(.vertical, 12)
                HStack(spacing: 8) {
                    Button("购买专业版") {
                        NSWorkspace.shared.open(Self.purchaseURL)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("已有许可证？") {
                        showLicenseSheet = true
                    }
                    .buttonStyle(PillButtonStyle(tint: .gray))
                }
            }
        }
    }

    // MARK: - Shared card chrome

    /// The rounded, faintly-filled container both states sit inside — mirrors the reference
    /// screenshot's single status card under the icon/title, rather than the previous flat list of
    /// sections with no visual boundary of its own.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private func labeledRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
        }
    }
}
