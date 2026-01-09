import SwiftUI

/// Badge component displaying WorkTree identifier in upper right corner of windows
struct WorkTreeBadge: View {
    private var workTreeSuffix: String? {
        WorkTreeIdentifier.workTreeSuffix
    }
    
    var body: some View {
        if let suffix = workTreeSuffix {
            Text(suffix)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }
}
