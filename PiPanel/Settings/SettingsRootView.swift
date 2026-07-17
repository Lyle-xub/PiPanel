import SwiftUI

/// Shared visual language for the Arc-inspired settings window. The hierarchy deliberately stays
/// native-macOS (real controls, traffic lights, keyboard focus) while the navigation, cards and
/// generous spacing give PiPanel a more recognisable product surface than a stock grouped Form.
enum SettingsTheme {
    static let accent = Color(red: 0.05, green: 0.45, blue: 1.0)
    static let indigo = Color(red: 0.20, green: 0.24, blue: 0.98)
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
            : NSColor(red: 0.995, green: 0.995, blue: 1.0, alpha: 1)
    })
    static let cardBorder = Color.primary.opacity(0.10)
    static let detailBackground = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1)
            : NSColor(red: 0.982, green: 0.982, blue: 0.988, alpha: 1)
    })
    static let topBar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.095, green: 0.095, blue: 0.11, alpha: 0.97)
            : NSColor(red: 1, green: 1, blue: 1, alpha: 0.96)
    })
}

enum SettingsLayout {
    static let pageMaxWidth: CGFloat = 700
    static let controlColumnWidth: CGFloat = 250
    static let rowHorizontalPadding: CGFloat = 16
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, picture, window, automation, shortcuts, membership, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .picture: "画面"
        case .window: "窗口"
        case .automation: "自动化"
        case .shortcuts: "快捷键"
        case .membership: "专业版"
        case .permissions: "权限"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .picture: "display"
        case .window: "macwindow"
        case .automation: "bolt"
        case .shortcuts: "keyboard"
        case .membership: "crown"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        VStack(spacing: 0) {
            settingsToolbar
            Divider().opacity(0.58)
            detailContent
                .id(selection)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.canvas)
        .tint(SettingsTheme.accent)
        .animation(.easeOut(duration: 0.16), value: selection)
    }

    private var settingsToolbar: some View {
        VStack(spacing: 8) {
            Text(selection.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary.opacity(0.82))
                .frame(height: 21)

            HStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: section.icon)
                                .font(.system(size: 21, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .frame(height: 24)
                            Text(section.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selection == section ? SettingsTheme.accent : Color.secondary)
                        .frame(width: 72, height: 62)
                        .background {
                            if selection == section {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(SettingsTheme.cardFill)
                                    .shadow(color: .black.opacity(0.09), radius: 13, y: 5)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(section.title)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .background(SettingsTheme.topBar)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .picture:
            PictureSettingsView()
        case .window:
            AppearanceSettingsView()
        case .automation:
            AutomationSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .membership:
            MembershipSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

// MARK: - Shared page chrome

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: SettingsLayout.pageMaxWidth)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsPageIntro: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tint: Color = SettingsTheme.accent,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 11)

            Divider().padding(.leading, 17)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 17)
    }
}

/// Native macOS controls do not all honor a parent frame's alignment in the same way (notably
/// Picker versus segmented controls). An explicit spacer is deterministic and gives every row the
/// exact same trailing edge.
struct SettingsTrailingControl<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content
        }
        .frame(width: SettingsLayout.controlColumnWidth)
    }
}

struct SettingsPopupControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) {
        self.options = options
        _selection = selection
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .frame(width: SettingsLayout.controlColumnWidth, height: 30)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SettingsSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) {
        self.options = options
        _selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(SettingsTheme.accent)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: SettingsLayout.controlColumnWidth, height: 32)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? SettingsTheme.accent : Color.primary.opacity(0.14))

                Circle()
                    .fill(.white)
                    .padding(2.5)
                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
            }
            .frame(width: 44, height: 24)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: configuration.isOn)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    init(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tint: Color = SettingsTheme.accent,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsTrailingControl {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(SettingsSwitchStyle())
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, detail == nil ? 12 : 10)
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let detail: String?
    let icon: String
    let tint: Color
    @ViewBuilder let control: Control

    init(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tint: Color = SettingsTheme.accent,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsTrailingControl {
                control
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, detail == nil ? 12 : 10)
    }
}

struct SettingsRowIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SettingsHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 17)
            .padding(.vertical, 11)
    }
}
