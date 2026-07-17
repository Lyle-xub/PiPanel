import SwiftUI
import UniformTypeIdentifiers

struct MembershipSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var membership = MembershipManager.shared
    @State private var showLicenseSheet = false
    @State private var showDeviceManagement = false
    @State private var showCancelTrialConfirmation = false
    @State private var showDeactivateConfirmation = false
    @State private var cardVariant = 0
    @State private var sharingPicker: NSSharingServicePicker?
    @State private var exportErrorMessage: String?

    private static let purchaseURL = URL(string: "https://pipanel.app")!

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                membershipPass
                accountColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: SettingsLayout.pageMaxWidth)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
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
        .alert("无法导出卡片", isPresented: exportErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "请稍后重试。")
        }
    }

    // MARK: - Membership pass

    private var membershipPass: some View {
        VStack(spacing: 11) {
            PiPanelIdentityCard(
                version: shortVersion,
                title: "PiPanel Pro",
                tagline: passCaption,
                variant: cardVariant
            )
            .frame(width: 218, height: 286)

            HStack(spacing: 0) {
                MembershipCardToolButton(icon: "dice.fill", help: "随机更换卡片样式") {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        cardVariant = (cardVariant + Int.random(in: 1...3)) % 4
                    }
                }
                .frame(maxWidth: .infinity)

                MembershipCardToolButton(icon: "square.and.arrow.up", help: "分享会员卡") {
                    shareCard()
                }
                .frame(maxWidth: .infinity)

                MembershipCardToolButton(icon: "arrow.down.to.line", help: "下载会员卡") {
                    downloadCard()
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 148)
        }
        .frame(width: 218)
    }

    private var passCaption: String {
        if membership.isLicensed { return "PRO MEMBER  •  ACTIVATED" }
        if membership.trialExpiresAt != nil { return "PRO TRIAL  •  ACTIVE" }
        return "WINDOWS, YOUR WAY"
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )
    }

    @MainActor
    private func renderedCardPNG() -> Data? {
        let card = PiPanelIdentityCard(
            version: shortVersion,
            title: "PiPanel Pro",
            tagline: passCaption,
            variant: cardVariant
        )
        .frame(width: 218, height: 286)
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 3

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    private func shareCard() {
        guard let data = renderedCardPNG() else {
            exportErrorMessage = "无法生成会员卡图片。"
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiPanel-Pro-Card.png")
        do {
            try data.write(to: url, options: .atomic)
            guard let anchorView = NSApp.keyWindow?.contentView else {
                exportErrorMessage = "找不到可用于显示分享菜单的窗口。"
                return
            }
            let picker = NSSharingServicePicker(items: [url])
            sharingPicker = picker
            picker.show(
                relativeTo: CGRect(x: anchorView.bounds.midX, y: anchorView.bounds.midY, width: 1, height: 1),
                of: anchorView,
                preferredEdge: .minY
            )
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func downloadCard() {
        guard let data = renderedCardPNG() else {
            exportErrorMessage = "无法生成会员卡图片。"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PiPanel-Pro-Card.png"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Account column

    private var accountColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusPanel

            if membership.isLicensed {
                activatedActions
            } else if membership.trialExpiresAt != nil {
                trialActions
            } else {
                inactiveActions
            }

            if let error = membership.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var statusPanel: some View {
        arcCard {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 38, height: 38)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(statusBadge)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }
            .padding(15)
        }
    }

    private var activatedActions: some View {
        arcCard {
            VStack(spacing: 0) {
                if let masked = membership.maskedLicenseKey {
                    detailRow(title: "许可证", value: masked, icon: "key.horizontal.fill")
                    Divider().padding(.leading, 48)
                }

                HStack(spacing: 12) {
                    actionIcon("laptopcomputer.and.iphone")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("设备管理")
                                .font(.system(size: 12.5, weight: .semibold))
                            if membership.activationCount > 0 {
                                Text(deviceUsageText)
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(SettingsTheme.accent)
                            }
                        }
                        Text("查看设备或释放旧设备名额")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("管理") {
                        showDeviceManagement = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(13)

                Divider().padding(.leading, 48)

                HStack {
                    Text("不再在这台 Mac 上使用专业版？")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消激活", role: .destructive) {
                        showDeactivateConfirmation = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .disabled(membership.isValidating)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
            }
        }
    }

    private var trialActions: some View {
        arcCard {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    actionIcon("calendar.badge.clock")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("7 天专业版试用")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(trialDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("购买专业版") {
                        NSWorkspace.shared.open(Self.purchaseURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(13)

                Divider().padding(.leading, 48)

                HStack {
                    Button("输入许可证") {
                        showLicenseSheet = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SettingsTheme.accent)
                    Spacer()
                    Button(membership.isCancellingTrial ? "正在取消…" : "取消试用", role: .destructive) {
                        showCancelTrialConfirmation = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(membership.isCancellingTrial || membership.isValidating)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 38)
            }
        }
    }

    private var inactiveActions: some View {
        arcCard {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("让每个窗口都随手悬浮")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("解锁自动整理、全局操作与完整的专业版体验。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("购买专业版") {
                        NSWorkspace.shared.open(Self.purchaseURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("输入许可证") {
                        showLicenseSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(15)
        }
    }

    private var trialDetail: String {
        if let days = membership.trialDaysRemaining {
            return "剩余 \(days) 天，期间可使用全部专业功能"
        }
        return "试用期间可使用全部专业功能"
    }

    private func detailRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            actionIcon(icon)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(13)
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SettingsTheme.accent)
            .frame(width: 30, height: 30)
            .background(SettingsTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func arcCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
    }

    private var statusIcon: String {
        if membership.isLicensed { return "checkmark.seal.fill" }
        if membership.trialExpiresAt != nil { return "clock.badge.checkmark.fill" }
        if membership.isTrialCancelled { return "xmark.circle.fill" }
        return "crown.fill"
    }

    private var statusTitle: String {
        if membership.isLicensed { return "专业版已激活" }
        if membership.trialExpiresAt != nil { return "正在试用专业版" }
        if membership.isTrialCancelled { return "专业版试用已取消" }
        return "升级到专业版"
    }

    private var statusSubtitle: String {
        if membership.isLicensed { return "PiPanel Pro 已在这台 Mac 上启用" }
        if membership.trialExpiresAt != nil { return "全部专业功能现已开放" }
        if membership.isTrialCancelled { return "仍可通过许可证重新激活" }
        return "更快地整理与控制所有画中画"
    }

    private var statusBadge: String {
        if membership.isLicensed { return "ACTIVE" }
        if membership.trialExpiresAt != nil { return "TRIAL" }
        return "PRO"
    }

    private var statusColor: Color {
        if membership.isLicensed { return .green }
        if membership.isTrialCancelled { return .secondary }
        return SettingsTheme.indigo
    }

    private var deviceUsageText: String {
        if let limit = membership.activationLimit {
            return "\(membership.activationCount) / \(limit)"
        }
        return "\(membership.activationCount) 台"
    }
}

private struct MembershipCardToolButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? SettingsTheme.accent : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovering ? SettingsTheme.accent.opacity(0.11) : Color.clear,
                    in: Circle()
                )
                .scaleEffect(isHovering ? 1.08 : 1)
                .offset(y: isHovering ? -2 : 0)
                .shadow(
                    color: SettingsTheme.accent.opacity(isHovering ? 0.16 : 0),
                    radius: 5,
                    y: 3
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isHovering)
        .help(help)
    }
}
