import SwiftUI

struct MembershipSettingsView: View {
    @ObservedObject private var membership = MembershipManager.shared
    @State private var licenseKeyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if membership.isMember {
                activatedSection
            } else {
                notActivatedSection
            }
        }
        .task {
            await membership.revalidate()
        }
    }

    private var activatedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("会员已激活", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            if let masked = membership.maskedLicenseKey {
                Text("激活码：\(masked)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button("取消激活", role: .destructive) {
                Task { await membership.deactivate() }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(membership.isValidating)
        }
    }

    private var notActivatedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("激活会员后可解锁全部设置（画面帧率、外观、默认位置等）")
                .font(.system(size: 12, weight: .semibold))

            Button("购买会员") {
                NSWorkspace.shared.open(MembershipManager.purchaseURL)
            }
            .buttonStyle(PillButtonStyle())

            Divider()

            Text("已经购买？输入激活码")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                TextField("激活码", text: $licenseKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button("激活") {
                    Task { await membership.activate(licenseKey: licenseKeyInput) }
                }
                .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || membership.isValidating)
            }

            if let error = membership.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }
}
