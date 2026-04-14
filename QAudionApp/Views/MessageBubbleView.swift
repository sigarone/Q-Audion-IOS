import SwiftUI

struct MessageBubbleView: View {
    let isSent: Bool
    let text: String
    let timestamp: Date
    let isEncrypted: Bool

    private var bubbleColor: Color {
        isSent ? .blue : Color(white: 0.18)
    }

    private var alignment: HorizontalAlignment {
        isSent ? .trailing : .leading
    }

    private var corners: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16)
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 48) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)

                HStack(spacing: 4) {
                    if isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                    }
                    Text(timestamp, style: .time)
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleColor)
            .clipShape(corners)

            if !isSent { Spacer(minLength: 48) }
        }
    }
}
