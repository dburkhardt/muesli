import SwiftUI

/// Reusable ellipsis (more actions) menu with native hover circle effect.
/// Matches Apple Notes-style icon buttons: subtle circular gray background on hover.
struct EllipsisActionsMenu<MenuContent: View>: View {
    let isReprocessing: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovered = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Group {
                if isReprocessing {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(
            Circle()
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help("More actions")
    }
}
