import Foundation

/// Offline unit conversion across common physical categories. Zero-permission.
/// Conversions only succeed within a single category (length↔length, etc.).
struct UnitConverterTool: Tool {
    let name = "unit_converter"
    let description = "Convert a value between units of the same kind (length, mass, temperature, volume, duration, speed, data). Example: value 5, from 'miles', to 'km'."

    var parameters: JSONSchema? {
        .object(
            description: "Unit conversion parameters",
            properties: [
                "value": .number(description: "The numeric amount to convert"),
                "from": .string(description: "Source unit, e.g. 'miles', 'kg', 'celsius'"),
                "to": .string(description: "Target unit, e.g. 'km', 'lb', 'fahrenheit'"),
            ],
            required: ["value", "from", "to"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let value = arguments["value"]?.doubleValue else {
            throw ToolError.missingArgument("value")
        }
        guard let fromRaw = arguments["from"]?.stringValue else {
            throw ToolError.missingArgument("from")
        }
        guard let toRaw = arguments["to"]?.stringValue else {
            throw ToolError.missingArgument("to")
        }

        guard let from = Self.lookup(fromRaw) else {
            throw ToolError.invalidArgument("from", expected: "a known unit (got '\(fromRaw)')")
        }
        guard let to = Self.lookup(toRaw) else {
            throw ToolError.invalidArgument("to", expected: "a known unit (got '\(toRaw)')")
        }
        guard from.category == to.category else {
            throw ToolError.executionFailed("can't convert \(from.category) to \(to.category)")
        }

        let result = Measurement(value: value, unit: from.dimension)
            .converted(to: to.dimension).value
        let formatted = String(format: "%.6g", result)
        return "\(String(format: "%.6g", value)) \(fromRaw) = \(formatted) \(toRaw)"
    }

    // MARK: - Unit table

    private struct UnitEntry { let dimension: Dimension; let category: String }

    private static func lookup(_ raw: String) -> UnitEntry? {
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "°", with: "")
        guard let (dim, cat) = table[key] else { return nil }
        return UnitEntry(dimension: dim, category: cat)
    }

    private static let table: [String: (Dimension, String)] = {
        var t: [String: (Dimension, String)] = [:]
        func add(_ dim: Dimension, _ cat: String, _ aliases: [String]) {
            for a in aliases { t[a] = (dim, cat) }
        }
        // Length
        add(UnitLength.meters, "length", ["m", "meter", "meters", "metre", "metres"])
        add(UnitLength.kilometers, "length", ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add(UnitLength.centimeters, "length", ["cm", "centimeter", "centimeters"])
        add(UnitLength.millimeters, "length", ["mm", "millimeter", "millimeters"])
        add(UnitLength.miles, "length", ["mi", "mile", "miles"])
        add(UnitLength.yards, "length", ["yd", "yard", "yards"])
        add(UnitLength.feet, "length", ["ft", "foot", "feet"])
        add(UnitLength.inches, "length", ["in", "inch", "inches"])
        add(UnitLength.nauticalMiles, "length", ["nmi", "nautical mile", "nautical miles"])
        // Mass
        add(UnitMass.kilograms, "mass", ["kg", "kilogram", "kilograms"])
        add(UnitMass.grams, "mass", ["g", "gram", "grams"])
        add(UnitMass.milligrams, "mass", ["mg", "milligram", "milligrams"])
        add(UnitMass.metricTons, "mass", ["t", "tonne", "tonnes", "metric ton", "metric tons"])
        add(UnitMass.pounds, "mass", ["lb", "lbs", "pound", "pounds"])
        add(UnitMass.ounces, "mass", ["oz", "ounce", "ounces"])
        add(UnitMass.stones, "mass", ["st", "stone", "stones"])
        // Temperature
        add(UnitTemperature.celsius, "temperature", ["c", "celsius", "centigrade"])
        add(UnitTemperature.fahrenheit, "temperature", ["f", "fahrenheit"])
        add(UnitTemperature.kelvin, "temperature", ["k", "kelvin"])
        // Volume
        add(UnitVolume.liters, "volume", ["l", "liter", "liters", "litre", "litres"])
        add(UnitVolume.milliliters, "volume", ["ml", "milliliter", "milliliters"])
        add(UnitVolume.gallons, "volume", ["gal", "gallon", "gallons"])
        add(UnitVolume.quarts, "volume", ["qt", "quart", "quarts"])
        add(UnitVolume.pints, "volume", ["pt", "pint", "pints"])
        add(UnitVolume.cups, "volume", ["cup", "cups"])
        add(UnitVolume.fluidOunces, "volume", ["floz", "fl oz", "fluid ounce", "fluid ounces"])
        // Duration
        add(UnitDuration.seconds, "duration", ["s", "sec", "secs", "second", "seconds"])
        add(UnitDuration.minutes, "duration", ["min", "mins", "minute", "minutes"])
        add(UnitDuration.hours, "duration", ["h", "hr", "hrs", "hour", "hours"])
        // Speed
        add(UnitSpeed.metersPerSecond, "speed", ["mps", "m/s", "meters per second"])
        add(UnitSpeed.kilometersPerHour, "speed", ["kph", "kmh", "km/h", "kilometers per hour"])
        add(UnitSpeed.milesPerHour, "speed", ["mph", "miles per hour"])
        add(UnitSpeed.knots, "speed", ["kn", "knot", "knots"])
        // Data
        add(UnitInformationStorage.bytes, "data", ["byte", "bytes", "b"])
        add(UnitInformationStorage.kilobytes, "data", ["kb", "kilobyte", "kilobytes"])
        add(UnitInformationStorage.megabytes, "data", ["mb", "megabyte", "megabytes"])
        add(UnitInformationStorage.gigabytes, "data", ["gb", "gigabyte", "gigabytes"])
        add(UnitInformationStorage.terabytes, "data", ["tb", "terabyte", "terabytes"])
        return t
    }()
}
