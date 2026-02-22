import SwiftUI

struct DraftTranscriptView: View {
    let text: String
    let speaker: TranscriptBlock.Speaker?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker {
                Text(speaker == .me ? "Me (draft)" : "Them (draft)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.body.italic())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
