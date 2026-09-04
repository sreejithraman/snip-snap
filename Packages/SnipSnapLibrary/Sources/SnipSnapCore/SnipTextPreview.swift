import Foundation

public enum SnipTextPreview {
    public static let characterLimit = 800

    public static func displayText(
        _ text: String,
        lineLimit: Int,
        characterLimit: Int = characterLimit
    ) -> String {
        guard lineLimit > 0, characterLimit > 0, !text.isEmpty else { return text }

        var characters = 0
        var lines = 1
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline {
                if lines == lineLimit {
                    return String(text[..<index])
                }
                lines += 1
            } else {
                if characters == characterLimit {
                    return String(text[..<index])
                }
                characters += 1
            }
            index = text.index(after: index)
        }
        return text
    }
}
