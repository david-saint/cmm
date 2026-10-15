import Foundation

// The plan is what `cmm plan --json` prints (schema 1). These types are read-only mirrors of it.
//
// Safety rule 2 depends on one property of this file: `Plan` and `PlanItem` have NO public initializer. A value of
// either type can only come out of a decoder, in practice out of `CmmClient.plan()`, so code outside this module
// (the SwiftUI app) cannot assemble a plan, or an item, and hand its paths to `apply`. Tests reach the internal
// initializers through `@testable import`.

/// How much thought an item deserves. Only `safe` items are ticked by default.
public enum Tier: Hashable, Sendable {
    case safe
    case review
    case manual
    /// A tier this app does not know. It is kept and shown, and never ticked by default.
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "safe": self = .safe
        case "review": self = .review
        case "manual": self = .manual
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .safe: "safe"
        case .review: "review"
        case .manual: "manual"
        case .other(let value): value
        }
    }
}

extension Tier: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// How cmm removes an item.
public enum ItemAction: Hashable, Sendable {
    /// The path is deleted from disk.
    case delete
    /// cmm runs a command (for example `brew cleanup`); the item's path is a label, not a file path.
    case command
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "delete": self = .delete
        case "command": self = .command
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .delete: "delete"
        case .command: "command"
        case .other(let value): value
        }
    }
}

extension ItemAction: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// One thing cmm would remove.
public struct PlanItem: Hashable, Sendable, Identifiable {
    public let rule: String
    public let group: String
    /// The opaque identity of the item. For `delete` items it is a file path; for `command` items it is a label
    /// such as `homebrew: cleanup`, and `note` is what to show.
    public let path: String
    public let bytes: Int64
    public let tier: Tier
    public let action: ItemAction
    public let note: String?

    public var id: String { path }
}

extension PlanItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rule, group, path, bytes, tier, action, note
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rule: try c.decode(String.self, forKey: .rule),
            group: try c.decode(String.self, forKey: .group),
            path: try c.decode(String.self, forKey: .path),
            bytes: try c.decode(Int64.self, forKey: .bytes),
            tier: try c.decode(Tier.self, forKey: .tier),
            action: try c.decode(ItemAction.self, forKey: .action),
            note: try c.decodeIfPresent(String.self, forKey: .note)
        )
    }
}

/// The volume cmm cleans and how much room it has now.
public struct Host: Hashable, Sendable {
    public let volume: String
    public let freeBytes: Int64
}

extension Host: Decodable {
    private enum CodingKeys: String, CodingKey {
        case volume
        case freeBytes = "free_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volume: try c.decode(String.self, forKey: .volume),
            freeBytes: try c.decode(Int64.self, forKey: .freeBytes)
        )
    }
}

/// A rule that left something out, and why. Information, not an error.
public struct Skip: Hashable, Sendable {
    public let rule: String
    public let reason: String
}

extension Skip: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rule, reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rule: try c.decode(String.self, forKey: .rule),
            reason: try c.decode(String.self, forKey: .reason)
        )
    }
}

/// Everything cmm would do, as metadata only (paths, sizes, tiers, reasons; never file contents).
public struct Plan: Equatable, Sendable {
    /// The one plan schema this app reads.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    /// When cmm made the plan. Informational: an unreadable timestamp is dropped rather than rejecting the plan.
    public let generatedAt: Date?
    public let host: Host
    public let items: [PlanItem]
    public let skipped: [Skip]
    public let totalBytes: Int64
}

extension Plan: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case host, items, skipped
        case totalBytes = "total_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The version comes first and alone: a plan of another schema may have a different shape, and the person
        // should be told "this app reads schema 1", not shown an unrelated decoding error.
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Plan.supportedSchemaVersion else { throw CmmError.unsupportedSchema(found: version) }

        let items = try c.decode([PlanItem].self, forKey: .items)
        self.init(
            schemaVersion: version,
            generatedAt: (try? c.decodeIfPresent(String.self, forKey: .generatedAt)).flatMap { $0 }.flatMap(Plan.timestamp),
            host: try c.decode(Host.self, forKey: .host),
            items: items,
            skipped: try c.decodeIfPresent([Skip].self, forKey: .skipped) ?? [],
            totalBytes: try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? items.reduce(0) { $0 + $1.bytes }
        )
    }

    /// Decodes the output of `cmm plan --json`. Every failure is a `CmmError` the app can show.
    static func parse(_ data: Data) throws -> Plan {
        do {
            return try JSONDecoder().decode(Plan.self, from: data)
        } catch let error as CmmError {
            throw error
        } catch let error as DecodingError {
            throw CmmError.malformedPlan(error.cmmDescription)
        } catch {
            throw CmmError.malformedPlan(error.localizedDescription)
        }
    }

    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension DecodingError {
    /// A short, human description that says where in the document the problem is, such as `items[0].path: missing`.
    var cmmDescription: String {
        switch self {
        case .keyNotFound(let key, let context):
            "\(Self.render(context.codingPath + [key])): missing"
        case .valueNotFound(_, let context):
            "\(Self.render(context.codingPath)): missing value"
        case .typeMismatch(let type, let context):
            "\(Self.render(context.codingPath)): wrong type (expected \(type))"
        case .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? "not valid JSON (\(context.debugDescription))"
                : "\(Self.render(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            localizedDescription
        }
    }

    private static func render(_ path: [any CodingKey]) -> String {
        var text = ""
        for key in path {
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return text.isEmpty ? "the plan" : text
    }
}
