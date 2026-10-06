import Foundation

/// Block-level Markdown for chat bubbles. SwiftUI `Text` only renders inline
/// Markdown (bold, italics, code spans, links) and drops line structure, so
/// replies are split into blocks first. Inline text inside each block is
/// rendered with `AttributedString(markdown:)`.
public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulletList([String])
    case orderedList(start: Int, items: [String])
    case codeBlock(language: String?, code: String)
    case quote(String)
    case rule
}

public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (an unclosed fence while streaming runs to the end).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // skip closing fence
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if bulletItem(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                    if let item = bulletItem(currentTrimmed) {
                        items.append(item)
                    } else if !currentTrimmed.isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += "\n" + currentTrimmed // continuation / nested line
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if let first = orderedItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                    if let item = orderedItem(currentTrimmed) {
                        items.append(item.text)
                    } else if !currentTrimmed.isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += "\n" + currentTrimmed
                    } else if currentTrimmed.isEmpty, index + 1 < lines.count,
                              orderedItem(lines[index + 1].trimmingCharacters(in: .whitespaces)) != nil {
                        // Loose list: blank line between numbered items.
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.orderedList(start: first.number, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")",
              rest.dropFirst().first == " " else { return nil }
        return (number, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
