import SwiftUI
import AgentCore

/// Renders assistant Markdown: paragraphs, headings, bullet and numbered
/// lists, fenced code blocks, quotes, and inline bold/italic/code/links.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(item)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).")
                            .monospacedDigit()
                        inline(item)
                    }
                }
            }
        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                inline(text)
                    .foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        Text(Self.attributed(text))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
