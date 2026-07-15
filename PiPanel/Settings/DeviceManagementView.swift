import SwiftUI

/// A live view of every Creem instance attached to the current license. Remote removal is useful
/// when an old Mac is no longer available; removing this Mac also clears its local entitlement.
struct DeviceManagementView: View {
    typealias Device = CreemClient.LicenseResponse.Instance

    @ObservedObject private var membership = MembershipManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRemoval: Device?
    @State private var isInitialLoad = true

    private var sortedDevices: [Device] {
        membership.instances.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == membership.ownInstanceId
            let rhsIsCurrent = rhs.id == membership.ownInstanceId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            return displayName(lhs).localizedStandardCompare(displayName(rhs)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageCard

                    if let message = membership.deviceManagementMessage {
                        feedbackBanner(message)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Text("已激活设备")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)

                    if sortedDevices.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(sortedDevices.enumerated()), id: \.element.id) { index, device in
                                deviceRow(device)
                                if index < sortedDevices.count - 1 {
                                    Divider().padding(.leading, 58)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(SettingsTheme.cardFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SettingsTheme.cardBorder, lineWidth: 1)
                        )
                    }

                    Label("移除旧设备会立即释放一个激活名额。被移除的设备再次使用专业功能时，需要重新输入许可证。", systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
                .padding(18)
                .animation(.easeInOut(duration: 0.2), value: membership.instances.map(\.id))
                .animation(.easeInOut(duration: 0.18), value: membership.deviceManagementMessage)
            }
        }
        .frame(width: 500, height: 470)
        .background(SettingsTheme.detailBackground)
        .task {
            await membership.refreshDevices(showSuccessMessage: false)
            isInitialLoad = false
        }
        .onChange(of: membership.isLicensed) { _, isLicensed in
            if !isLicensed { dismiss() }
        }
        .onDisappear {
            membership.clearDeviceManagementMessage()
        }
        .alert(item: $pendingRemoval) { device in
            let isCurrent = device.id == membership.ownInstanceId
            return Alert(
                title: Text(isCurrent ? "取消激活这台 Mac？" : "移除这台设备？"),
                message: Text(removalMessage(for: device, isCurrent: isCurrent)),
                primaryButton: .destructive(Text(isCurrent ? "取消激活" : "移除设备")) {
                    Task {
                        let removed = await membership.deactivateInstance(device)
                        if removed && isCurrent { dismiss() }
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SettingsTheme.accent)
                .frame(width: 34, height: 34)
                .background(SettingsTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("设备管理")
                    .font(.system(size: 15, weight: .semibold))
                Text("查看和管理占用许可证名额的设备")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await membership.refreshDevices() }
            } label: {
                if membership.isValidating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .help("刷新设备列表")
            .disabled(membership.isValidating || membership.isDeactivatingInstanceId != nil)

            Button("完成") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var usageCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SettingsTheme.accent.opacity(0.11))
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(SettingsTheme.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text(usageTitle)
                    .font(.system(size: 14, weight: .semibold))
                if let updatedAt = membership.devicesLastUpdatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("正在读取许可证设备信息…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let limit = membership.activationLimit {
                Text("\(membership.activationCount) / \(limit)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsTheme.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(SettingsTheme.accent.opacity(0.10), in: Capsule())
                    .help("已使用 \(membership.activationCount) 个，共 \(limit) 个激活名额")
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [SettingsTheme.accent.opacity(0.10), SettingsTheme.cardFill],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SettingsTheme.accent.opacity(0.13), lineWidth: 1)
        )
    }

    private var usageTitle: String {
        let count = membership.activationCount
        if let limit = membership.activationLimit {
            return count >= limit ? "激活名额已用完" : "已激活 \(count) 台设备"
        }
        return "已激活 \(count) 台设备"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if isInitialLoad && membership.isValidating {
                ProgressView().controlSize(.small)
                Text("正在加载设备…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "laptopcomputer.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(membership.deviceManagementMessageIsError ? "暂时无法显示设备" : "没有已激活的设备")
                    .font(.system(size: 12, weight: .medium))
                if membership.deviceManagementMessageIsError {
                    Button("重试") {
                        Task { await membership.refreshDevices(showSuccessMessage: false) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(membership.isValidating)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SettingsTheme.cardBorder, lineWidth: 1)
        )
    }

    private func deviceRow(_ device: Device) -> some View {
        let isCurrent = device.id == membership.ownInstanceId
        let isRemoving = membership.isDeactivatingInstanceId == device.id

        return HStack(spacing: 12) {
            Image(systemName: isCurrent ? "macbook" : "desktopcomputer")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isCurrent ? SettingsTheme.accent : .secondary)
                .frame(width: 34, height: 34)
                .background(
                    (isCurrent ? SettingsTheme.accent.opacity(0.11) : Color.primary.opacity(0.045)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(displayName(device))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if isCurrent {
                        Text("这台 Mac")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SettingsTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SettingsTheme.accent.opacity(0.10), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.status.lowercased() == "active" ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(device.status.lowercased() == "active" ? "已激活" : "状态：\(device.status)")
                    Text("·")
                    Text("ID \(shortDeviceID(device.id))")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Button(role: .destructive) {
                pendingRemoval = device
            } label: {
                if isRemoving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isCurrent ? "取消激活" : "移除")
                }
            }
            .buttonStyle(PillButtonStyle(tint: .red))
            .disabled(
                membership.isValidating
                    || (membership.isDeactivatingInstanceId != nil && !isRemoving)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func feedbackBanner(_ message: String) -> some View {
        let isError = membership.deviceManagementMessageIsError
        let tint = isError ? Color.red : Color.green
        return HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            Text(message)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button {
                membership.clearDeviceManagementMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func displayName(_ device: Device) -> String {
        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "未命名设备" : name
    }

    private func shortDeviceID(_ id: String) -> String {
        let suffix = id.suffix(8)
        return suffix.count == id.count ? id : "••••\(suffix)"
    }

    private func removalMessage(for device: Device, isCurrent: Bool) -> String {
        if isCurrent {
            return "“\(displayName(device))”将立即失去专业版权限，并释放一个激活名额。之后可使用同一个许可证重新激活。"
        }
        return "确定移除“\(displayName(device))”吗？该设备将失去专业版权限，并释放一个激活名额。"
    }
}
