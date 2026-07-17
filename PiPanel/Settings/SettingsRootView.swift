import SwiftUI

/// Shared visual tokens for the settings window. A restrained blue accent and adaptive system
/// surfaces keep the pages readable in both light and dark appearances without each page
/// inventing its own colors.
enum SettingsTheme {
    static let accent = Color(red: 0.24, green: 0.48, blue: 0.96)
    static let detailBackground = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color(nsColor: .textBackgroundColor).opacity(0.72)
    static let cardBorder = Color.primary.opacity(0.08)
}

private struct SettingsPageFormModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .tint(SettingsTheme.accent)
            .environment(\.defaultMinListRowHeight, 36)
    }
}

extension View {
    func settingsPageFormStyle() -> some View {
        modifier(SettingsPageFormModifier())
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .permissions: return "权限"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "启动行为与免费版功能说明"
        case .permissions: return "管理屏幕录制与辅助功能权限"
        case .about: return "版本信息、更新与恢复设置"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .blue
        case .permissions: return .teal
        case .about: return .gray
        }
    }
}

struct SettingsRootView: View {
    @State private var selection: SettingsSection? = .general

    private var selectedSection: SettingsSection { selection ?? .general }

    private var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                detailContent
            }
            .background(SettingsTheme.detailBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tint(SettingsTheme.accent)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: SettingsTheme.accent.opacity(0.16), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PiPanel")
                        .font(.system(size: 14, weight: .semibold))
                    Text("设置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 42)
            .padding(.bottom, 14)

            Divider().opacity(0.55)

            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                        .font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: section.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(section.tint)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(section.tint.opacity(0.14))
                        )
                }
                .tag(section)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 165, ideal: 180, max: 205)
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedSection.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selectedSection.tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedSection.tint.opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSection.title)
                    .font(.system(size: 22, weight: .bold))
                Text(selectedSection.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 27)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [selectedSection.tint.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipped()
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}
