import SwiftUI

struct ActiveSessionsView: View {
    @EnvironmentObject private var sessionManager: PiPSessionManager

    var body: some View {
        if !sessionManager.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在画中画")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    ForEach(sessionManager.sessions) { session in
                        HoverableRow {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 6, height: 6)
                                Text(session.windowInfo.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    sessionManager.stopSession(session)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
