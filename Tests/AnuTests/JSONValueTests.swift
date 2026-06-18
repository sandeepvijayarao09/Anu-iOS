import XCTest
@testable import Anu

final class JSONValueTests: XCTestCase {

    func testDecodeFromRawJSON() throws {
        let data = Data(#"{"name": "test", "count": 3, "ratio": 0.5, "on": true, "tags": ["a", "b"], "nothing": null}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(value["name"]?.stringValue, "test")
        XCTAssertEqual(value["count"]?.intValue, 3)
        XCTAssertEqual(value["ratio"]?.doubleValue, 0.5)
        XCTAssertEqual(value["on"]?.boolValue, true)
        XCTAssertEqual(value["tags"]?[0]?.stringValue, "a")
        XCTAssertEqual(value["nothing"]?.isNull, true)
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = JSONValue.object([
            "nested": .object(["k": .int(7)]),
            "list": .array([.string("x"), .bool(false)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testIntDoubleCoercion() {
        XCTAssertEqual(JSONValue.double(5.0).intValue, 5)
        XCTAssertEqual(JSONValue.int(5).doubleValue, 5.0)
    }

    func testPrettyJSONIsValid() throws {
        let value = JSONValue.object(["key": .string("value")])
        let pretty = value.prettyJSON
        XCTAssertTrue(pretty.contains("\"key\""))
        // Must parse back as valid JSON
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(pretty.utf8)))
    }

    func testSubscriptOutOfBoundsIsNil() {
        let arr = JSONValue.array([.int(1)])
        XCTAssertNil(arr[5])
        XCTAssertNil(arr["key"])
    }
}
