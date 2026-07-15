import SwiftUI

/// The "已有许可证?" flow — a standalone sheet rather than inline in MembershipSettingsView's main
/// card, so that card can stay as minimal as the reference design (icon, status, two buttons)
/// instead of permanently showing a license-key field and a recovery-email field whether or not
/// the user actually wants either right now. Covers both ways of getting back onto a license: enter
/// the key directly, or recover it by the purchase email if it's been lost.
struct LicenseActivationSheetView: View {
    @ObservedObject private var membership = MembershipManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var licenseKeyInput = ""
    @State private var recoveryEmailInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已有许可证")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("输入许可证")
                    .font(.system(size: 12, weight: .semibold))
                HStack {
                    TextField("激活码", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("激活") {
                        Task {
                            await membership.activate(licenseKey: licenseKeyInput)
                            if membership.isLicensed { dismiss() }
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || membership.isValidating)
                }
                if let error = membership.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("忘记许可证？用购买邮箱找回")
                    .font(.system(size: 12, weight: .semibold))
                HStack {
                    TextField("购买时的邮箱", text: $recoveryEmailInput)
                        .textFieldStyle(.roundedBorder)
                    Button("发送找回邮件") {
                        Task { await membership.requestRecovery(email: recoveryEmailInput) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(recoveryEmailInput.trimmingCharacters(in: .whitespaces).isEmpty || membership.isRequestingRecovery)
                }
                if let status = membership.recoveryStatusMessage {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear { membership.errorMessage = nil }
    }
}
