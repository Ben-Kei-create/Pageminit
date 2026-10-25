import Foundation

public enum ReadingDirection: String, Codable, Sendable {
    case ltr, rtl
}

public struct BookMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var creator: String?
    public var publisher: String?
    public var languageTag: String
    public var description: String?
    public var uniqueIdentifier: String
    public var readingDirection: ReadingDirection

    public init(
        title: String, subtitle: String? = nil, creator: String? = nil, publisher: String? = nil,
        languageTag: String = "ja", description: String? = nil,
        uniqueIdentifier: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        readingDirection: ReadingDirection = .ltr
    ) {
        self.title = title
        self.subtitle = subtitle
        self.creator = creator
        self.publisher = publisher
        self.languageTag = languageTag
        self.description = description
        self.uniqueIdentifier = uniqueIdentifier
        self.readingDirection = readingDirection
    }
}

public enum Severity: String, Codable, Sendable {
    case info, warning, error, fatal
}

public struct Issue: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let category: String   // input, quality, epub, store, a11y, system
    public let severity: Severity
    public let code: String
    public let message: String
    public let path: String?
    public let sourceLine: Int?

    public init(
        category: String, severity: Severity, code: String, message: String,
        path: String? = nil, sourceLine: Int? = nil
    ) {
        self.id = UUID()
        self.category = category
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
        self.sourceLine = sourceLine
    }
}
