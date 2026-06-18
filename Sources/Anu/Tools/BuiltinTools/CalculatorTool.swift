import Foundation

/// A tool that evaluates mathematical expressions
struct CalculatorTool: Tool {
    let name = "calculator"
    let description = "Evaluates mathematical expressions. Supports +, -, *, /, ^, sqrt(), abs(), floor(), ceil(), round(), sin(), cos(), tan(), log(), exp() and parentheses."

    var parameters: JSONSchema? {
        .object(
            description: "Calculator parameters",
            properties: [
                "expression": .string(description: "The mathematical expression to evaluate, e.g. '2 + 3 * 4' or 'sqrt(16)'")
            ],
            required: ["expression"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let expression = arguments["expression"]?.stringValue else {
            throw ToolError.missingArgument("expression")
        }

        do {
            let result = try evaluate(expression: expression)
            guard result.isFinite else {
                throw ToolError.executionFailed("result is not a finite number (\(result))")
            }
            // Only convert to Int when it's safely representable — Int(Double)
            // traps on NaN/Inf and on magnitudes beyond Int's range.
            if result.rounded() == result, abs(result) < 9.0e15 {
                return "\(expression) = \(Int(result))"
            } else {
                return "\(expression) = \(String(format: "%.6g", result))"
            }
        } catch {
            throw ToolError.executionFailed(error.localizedDescription)
        }
    }

    // MARK: - Expression Evaluator

    private func evaluate(expression: String) throws -> Double {
        var parser = ExpressionParser(expression: expression)
        return try parser.parse()
    }
}

// MARK: - Recursive Descent Parser

private struct ExpressionParser {
    let tokens: [Token]
    var pos: Int = 0

    enum Token {
        case number(Double)
        case plus, minus, multiply, divide, power
        case lparen, rparen
        case name(String)
        case comma
    }

    init(expression: String) {
        self.tokens = Self.tokenize(expression)
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c.isWhitespace {
                i = input.index(after: i)
                continue
            }
            if c.isNumber || (c == "." && input.index(after: i) < input.endIndex) {
                var numStr = ""
                while i < input.endIndex && (input[i].isNumber || input[i] == ".") {
                    numStr.append(input[i])
                    i = input.index(after: i)
                }
                if let val = Double(numStr) { tokens.append(.number(val)) }
                continue
            }
            if c.isLetter || c == "_" {
                var name = ""
                while i < input.endIndex && (input[i].isLetter || input[i].isNumber || input[i] == "_") {
                    name.append(input[i])
                    i = input.index(after: i)
                }
                tokens.append(.name(name))
                continue
            }
            switch c {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.multiply)
            case "/": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case ",": tokens.append(.comma)
            default: break
            }
            i = input.index(after: i)
        }
        return tokens
    }

    mutating func parse() throws -> Double {
        let result = try parseAddSub()
        return result
    }

    mutating func parseAddSub() throws -> Double {
        var left = try parseMulDiv()
        while pos < tokens.count {
            if case .plus = tokens[pos] {
                pos += 1; left += try parseMulDiv()
            } else if case .minus = tokens[pos] {
                pos += 1; left -= try parseMulDiv()
            } else { break }
        }
        return left
    }

    mutating func parseMulDiv() throws -> Double {
        var left = try parsePower()
        while pos < tokens.count {
            if case .multiply = tokens[pos] {
                pos += 1; left *= try parsePower()
            } else if case .divide = tokens[pos] {
                pos += 1
                let right = try parsePower()
                guard right != 0 else { throw ToolError.executionFailed("Division by zero") }
                left /= right
            } else { break }
        }
        return left
    }

    mutating func parsePower() throws -> Double {
        let base = try parseUnary()
        if pos < tokens.count, case .power = tokens[pos] {
            pos += 1
            let exp = try parsePower()
            return pow(base, exp)
        }
        return base
    }

    mutating func parseUnary() throws -> Double {
        if pos < tokens.count, case .minus = tokens[pos] {
            pos += 1
            // Negate the full power expression so -2^2 == -(2^2) == -4,
            // matching standard math precedence.
            return try -parsePower()
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> Double {
        guard pos < tokens.count else { throw ToolError.executionFailed("Unexpected end of expression") }
        switch tokens[pos] {
        case .number(let val):
            pos += 1
            return val
        case .lparen:
            pos += 1
            let val = try parseAddSub()
            guard pos < tokens.count, case .rparen = tokens[pos] else {
                throw ToolError.executionFailed("Missing closing parenthesis")
            }
            pos += 1
            return val
        case .name(let funcName):
            pos += 1
            guard pos < tokens.count, case .lparen = tokens[pos] else {
                // Treat as constant
                return try resolveConstant(funcName)
            }
            pos += 1
            var args: [Double] = []
            while pos < tokens.count {
                if case .rparen = tokens[pos] { break }
                if !args.isEmpty {
                    guard case .comma = tokens[pos] else { throw ToolError.executionFailed("Expected comma in function args") }
                    pos += 1
                }
                args.append(try parseAddSub())
            }
            guard pos < tokens.count, case .rparen = tokens[pos] else {
                throw ToolError.executionFailed("Missing closing parenthesis in function call")
            }
            pos += 1
            return try callFunction(funcName, args: args)
        default:
            throw ToolError.executionFailed("Unexpected token in expression")
        }
    }

    func resolveConstant(_ name: String) throws -> Double {
        switch name.lowercased() {
        case "pi": return Double.pi
        case "e": return M_E
        case "inf", "infinity": return Double.infinity
        default: throw ToolError.executionFailed("Unknown identifier: \(name)")
        }
    }

    func callFunction(_ name: String, args: [Double]) throws -> Double {
        let fn = name.lowercased()
        // Validate arity before indexing — an empty sqrt() or a one-arg
        // atan2() must error, not trap on args[0]/args[1].
        let unary: Set<String> = ["sqrt", "abs", "floor", "ceil", "round", "sin",
                                   "cos", "tan", "asin", "acos", "atan", "log",
                                   "ln", "log10", "log2", "exp"]
        let binary: Set<String> = ["atan2", "pow", "min", "max"]
        if unary.contains(fn) {
            guard args.count == 1 else {
                throw ToolError.executionFailed("\(fn) expects 1 argument, got \(args.count)")
            }
        } else if binary.contains(fn) {
            guard args.count == 2 else {
                throw ToolError.executionFailed("\(fn) expects 2 arguments, got \(args.count)")
            }
        }

        switch fn {
        case "sqrt": return sqrt(args[0])
        case "abs": return abs(args[0])
        case "floor": return floor(args[0])
        case "ceil": return ceil(args[0])
        case "round": return Foundation.round(args[0])
        case "sin": return sin(args[0])
        case "cos": return cos(args[0])
        case "tan": return tan(args[0])
        case "asin": return asin(args[0])
        case "acos": return acos(args[0])
        case "atan": return atan(args[0])
        case "atan2": return atan2(args[0], args[1])
        case "log", "ln": return log(args[0])
        case "log10": return log10(args[0])
        case "log2": return log2(args[0])
        case "exp": return exp(args[0])
        case "pow": return pow(args[0], args[1])
        case "min": return Swift.min(args[0], args[1])
        case "max": return Swift.max(args[0], args[1])
        default: throw ToolError.executionFailed("Unknown function: \(name)")
        }
    }
}
