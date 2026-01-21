import SwiftUI

/// A link-styled button with hover state feedback
/// Used for secondary actions like "Check Again" in onboarding
struct HoverableLink: View {
    let title: String
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(isHovered ? Color.accentColor.opacity(0.7) : Color.accentColor)
            .underline(isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
