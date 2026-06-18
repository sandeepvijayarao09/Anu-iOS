import Foundation

// MARK: - JSONValue

/// A recursive enum to represent any JSON value
indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    // MARK: Subscript

    subscript(_ key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(_ index: Int) -> JSONValue? {
        if case .array(let arr) = self, index < arr.count { return arr[index] }
        return nil
    }

    // MARK: Accessors

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Conversion to Foundation types

    var rawValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.rawValue as Any }
        case .object(let o): return o.mapValues { $0.rawValue as Any }
        }
    }

    // MARK: Pretty printing

    var prettyJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - JSON Schema Builder

final class JSONSchema: Encodable, Sendable {
    enum SchemaType: String, Encodable {
        case object, array, string, number, integer, boolean, null
    }

    let type: SchemaType
    let description: String?
    let properties: [String: JSONSchema]?
    let required: [String]?
    let items: JSONSchema?
    let enumValues: [JSONValue]?

    init(
        type: SchemaType,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        items: JSONSchema? = nil,
        enumValues: [JSONValue]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }

    static func object(
        description: String? = nil,
        properties: [String: JSONSchema],
        required: [String]? = nil
    ) -> JSONSchema {
        JSONSchema(type: .object, description: description, properties: properties, required: required)
    }

    static func string(description: String? = nil, enumValues: [String]? = nil) -> JSONSchema {
        JSONSchema(
            type: .string,
            description: description,
            enumValues: enumValues.map { $0.map { JSONValue.string($0) } }
        )
    }

    static func number(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .number, description: description)
    }

    static func integer(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .integer, description: description)
    }

    static func boolean(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .boolean, description: description)
    }

    static func array(items: JSONSchema, description: String? = nil) -> JSONSchema {
        JSONSchema(type: .array, description: description, items: items)
    }
}
