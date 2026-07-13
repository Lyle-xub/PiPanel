import SwiftUI

struct WindowPickerView: View {
    @EnvironmentObject private var sessionManager: PiPSessionManager
    @State private var windows: [WindowInfo] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var groupedWindows: [(appName: String, windows: [WindowInfo])] {
        Dictionary(grouping: windows, by: \.ownerAppName)
            .map { (appName: $0.key, windows: $0.value) }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选择要画中画的窗口")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SubtleIconButtonStyle())
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if windows.isEmpty {
                Text("没有可用窗口")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedWindows, id: \.appName) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.appName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                ForEach(group.windows) { window in
                                    Button {
                                        sessionManager.startSession(for: window)
                                    } label: {
                                        HoverableRow {
                                            HStack(spacing: 8) {
                                                Image(systemName: "macwindow")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 16)
                                                Text(window.title)
                                                    .font(.system(size: 12))
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 400, maxHeight: 1000)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            windows = try await WindowEnumerator.listPiPCandidateWindows()
        } catch {
            loadError = "无法获取窗口列表，请检查屏幕录制权限"
            windows = []
        }
        isLoading = false
    }
}
