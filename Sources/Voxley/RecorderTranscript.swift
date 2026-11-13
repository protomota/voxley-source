import SwiftUI

struct RecorderTranscript: View {
    let text: String
    let status: String

    var body: some View {
        let hasTranscript = !text.isEmpty
        let font = Font.system(size: 13, weight: hasTranscript ? .medium : .regular)

        // Measure three lines using the same font as the transcript.
        Text("Ag\nAg\nAg")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                ScrollView(.vertical) {
                    Text(verbatim: hasTranscript ? text : status)
                        .font(font)
                        .foregroundStyle(hasTranscript ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollIndicators(.hidden)
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasTranscript ? "Live transcript: \(text)" : status)
    }
}
