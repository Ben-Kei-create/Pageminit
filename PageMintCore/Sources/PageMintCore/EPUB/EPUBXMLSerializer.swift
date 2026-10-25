import Foundation

public enum XMLSerializationError: Error, Equatable, Sendable {
    case invalidCharacter(UInt32)
}

/// XML/XHTMLへ差し込む文字列は必ずここを通す (設計書 §3.3 セキュリティ)。
public enum EPUBXMLSerializer {
    /// テキストノード・属性値の両方で安全なエスケープ。XML 1.0で許されない文字は拒否する(黙って削除しない)。
    public static func escape(_ value: String) throws -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            guard isXMLChar(scalar) else { throw XMLSerializationError.invalidCharacter(scalar.value) }
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// XML 1.0 Char 生成規則。
    static func isXMLChar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF: return true
        case 0xE000...0xFFFD: return true
        case 0x10000...0x10FFFF: return true
        default: return false
        }
    }
}

public enum BookMetadataValidator {
    /// 構文のみの簡易BCP47検査 (言語サブタグレジストリ照合はしない)。
    static func isPlausibleBCP47(_ tag: String) -> Bool {
        tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }

    public static func validate(_ m: BookMetadata) -> [Issue] {
        var issues: [Issue] = []
        func add(_ sev: Severity, _ code: String, _ msg: String) {
            issues.append(Issue(category: "input", severity: sev, code: code, message: msg))
        }
        let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { add(.error, "PM-META-001", "書籍タイトルを入力してください。") }
        if title.count > 200 { add(.warning, "PM-META-002", "タイトルが200文字を超えています。") }
        if m.title.unicodeScalars.contains(where: { !EPUBXMLSerializer.isXMLChar($0) || $0.value < 0x20 || $0.value == 0x7F }) {
            add(.error, "PM-META-003", "タイトルに使用できない制御文字が含まれています。")
        }
        if !isPlausibleBCP47(m.languageTag) { add(.error, "PM-META-004", "言語タグが不正です (例: ja, en, ja-JP)。") }
        if m.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.error, "PM-META-005", "識別子が空です。")
        }
        if (m.creator ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.warning, "PM-META-006", "著者が未設定です。")
        }
        return issues
    }
}
