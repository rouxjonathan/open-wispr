import Foundation

public struct TextPostProcessor {
    private static let replacements: [(pattern: String, replacement: String)] = [
        ("\\bperiod\\b", "."),
        ("\\bfull stop\\b", "."),
        ("\\b[ck]a?r?ma\\b", ","),
        ("\\bcomma\\b", ","),
        ("\\bquestion mark\\b", "?"),
        ("\\bexclamation mark\\b", "!"),
        ("\\bexclamation point\\b", "!"),
        ("\\bcolon\\b", ":"),
        ("\\bsemicolon\\b", ";"),
        ("\\bsemi colon\\b", ";"),
        ("\\bellipsis\\b", "..."),
        ("\\bdash\\b", " —"),
        ("\\bhyphen\\b", "-"),
        ("\\bopen quote\\b", "\""),
        ("\\bclose quote\\b", "\""),
        ("\\bopen paren\\b", "("),
        ("\\bclose paren\\b", ")"),
        ("\\bnew line\\b", "\n"),
        ("\\bnewline\\b", "\n"),
        ("\\bnew paragraph\\b", "\n\n"),
    ]

    public static func process(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        result = fixSpacingAroundPunctuation(result)
        result = ensureSpaceAfterPunctuation(result)
        return result
    }

    public static func applyReplacements(_ text: String, replacements: [(String, String)]) -> String {
        guard !replacements.isEmpty else { return text }
        var result = text
        for (from, to) in replacements {
            guard !from.isEmpty else { continue }
            let escapedFrom = NSRegularExpression.escapedPattern(for: from)
            let pattern = "\\b\(escapedFrom)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let escapedTo = NSRegularExpression.escapedTemplate(for: to)
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: escapedTo
            )
        }
        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\s+([.,?!:;])", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1"
        )
        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "([.,?!:;])(\\w)", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )
        return result
    }
}
