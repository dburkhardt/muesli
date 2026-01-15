import SwiftUI

/// About dialog window for Muesli
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // App icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            
            // App name
            Text(appName)
                .font(.system(size: 28, weight: .bold))
            
            // Version
            Text("Version \(appVersion)")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            
            // Copyright
            Text("© 2024 Muesli")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            // Description
            Text("Local-first meeting transcription for macOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
                .frame(height: 10)
            
            // OK button
            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 100)
        }
        .padding(40)
        .frame(width: 400, height: 500)
    }
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    AboutView()
}
