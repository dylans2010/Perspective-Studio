import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation

    private var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(conversation.updatedAt) {
            return "Today"
        } else if calendar.isDateInYesterday(conversation.updatedAt) {
            return "Yesterday"
        } else {
            return conversation.updatedAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(dateLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conversation: \(conversation.title), \(dateLabel)")
        .accessibilityHint("Double tap to open")
    }
}
