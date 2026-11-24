import Foundation

/// Works out what was typed, when what was typed is arithmetic.
///
/// The syntax is the one everybody already knows from Python and school
/// algebra, with one deliberate difference: `^` raises to a power rather than
/// meaning bitwise exclusive-or. In a box where people type `2^10` expecting
/// 1024, the programmer's reading would be a trap.
///
/// Nothing here throws for the user's benefit. A half-typed expression is the
/// normal state of a box being typed into, so anything that does not parse
/// simply has no answer and shows no row.
public enum Calculator {
    /// The answer, or nothing when the text is not arithmetic.
    public static func evaluate(_ text: String) -> Double? {
        var parser = Parser(text: text)

        guard let value = parser.parseExpression(minimumPrecedence: 0),
              parser.isFinished,
              value.isFinite else {
            return nil
        }

        return value
    }

    /// Whether the text is worth showing an answer for.
    ///
    /// A bare number is not: `42` answers itself, and a ten digit one is a
    /// timestamp that the epoch conversion already explains. There has to be
    /// something to work out.
    public static func isWorthEvaluating(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return false
        }

        let hasOperation = trimmed.contains { "+-*/%^()".contains($0) }
        let hasWord = trimmed.rangeOfCharacter(from: .letters) != nil

        return hasOperation || hasWord
    }

    /// Grouped for reading, and trimmed of the noise a `Double` carries: the
    /// answer to `0.1 + 0.2` is `0.3` here rather than seventeen decimal
    /// places of binary floating point.
    public static func display(_ value: Double) -> String {
        let rounded = (value * roundingScale).rounded() / roundingScale
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = maximumFractionDigits

        return formatter.string(from: NSNumber(value: rounded)) ?? plain(rounded)
    }

    /// The same number without the grouping, which is what belongs on the
    /// pasteboard: a comma pasted into a spreadsheet is not a number.
    public static func plain(_ value: Double) -> String {
        let rounded = (value * roundingScale).rounded() / roundingScale

        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = maximumFractionDigits

        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }

    private static let maximumFractionDigits = 10
    /// Floating point arithmetic leaves dust: `0.1 + 0.2` is not quite `0.3`.
    /// Rounding at the tenth decimal sweeps it up without touching any answer
    /// a person typed.
    private static let roundingScale: Double = 1e10
}

/// Reads the text left to right, building the answer as it goes.
///
/// Precedence climbing rather than a tree: there is nothing to do with an
/// expression here but work out its value, so there is no reason to build one.
private struct Parser {
    private let characters: [Character]
    private var index = 0
    /// Set while reading the right side of `+` or `-`, where a trailing `%`
    /// belongs to the sum rather than to the number.
    private var suppressesPercent = false

    init(text: String) {
        characters = Array(text)
    }

    var isFinished: Bool {
        var copy = self
        copy.skipWhitespace()
        return copy.index >= copy.characters.count
    }

    /// Binding power of each operator. Higher binds tighter.
    private static let precedence: [String: Int] = [
        "+": 1,
        "-": 1,
        "*": 2,
        "/": 2,
        "%": 2,
        "^": 3,
        "**": 3,
    ]

    static let powerPrecedence = 3

    /// `2 ^ 3 ^ 2` is 512, not 64: powers group to the right, the way they do
    /// on paper.
    private static let rightAssociative: Set<String> = ["^", "**"]

    mutating func parseExpression(minimumPrecedence: Int) -> Double? {
        guard var left = parseUnary() else {
            return nil
        }

        while let op = peekOperator(), let precedence = Self.precedence[op], precedence >= minimumPrecedence {
            consume(op.count)

            // `45 + 20%` means 54: a percentage added to something is a
            // share of that something, which is how people say it out loud.
            if (op == "+" || op == "-"), let share = parsePercentageShare() {
                left = op == "+" ? left + left * share : left - left * share
                continue
            }

            let next = Self.rightAssociative.contains(op) ? precedence : precedence + 1

            guard let right = parseExpression(minimumPrecedence: next) else {
                return nil
            }

            guard let value = Self.apply(op, left, right) else {
                return nil
            }

            left = value
        }

        return left
    }

    private static func apply(_ op: String, _ left: Double, _ right: Double) -> Double? {
        switch op {
        case "+":
            return left + right
        case "-":
            return left - right
        case "*":
            return left * right
        case "/":
            // No answer rather than an infinity: a box showing `inf` has told
            // the user nothing they did not already know.
            return right == 0 ? nil : left / right
        case "%":
            return right == 0 ? nil : left.truncatingRemainder(dividingBy: right)
        case "^", "**":
            return pow(left, right)
        default:
            return nil
        }
    }

    /// A trailing `%` on the right of a `+` or `-`, as in `45 + 20%`, read as
    /// the fraction it stands for.
    private mutating func parsePercentageShare() -> Double? {
        let saved = index
        suppressesPercent = true
        let parsed = parseUnary()
        suppressesPercent = false

        guard let value = parsed else {
            index = saved
            return nil
        }

        skipWhitespace()

        guard index < characters.count, characters[index] == "%" else {
            index = saved
            return nil
        }

        // Only when the percentage ends the term: `45 + 20% * 2` is ordinary
        // arithmetic and should stay that way.
        index += 1
        skipWhitespace()

        guard index >= characters.count || characters[index] == ")" else {
            index = saved
            return nil
        }

        return value / 100
    }

    private mutating func parseUnary() -> Double? {
        skipWhitespace()

        guard index < characters.count else {
            return nil
        }

        if characters[index] == "-" {
            index += 1
            // Looser than a power and tighter than anything else, so `-2^2`
            // is -4 while `-2 * 3` is still -6.
            return parseExpression(minimumPrecedence: Self.powerPrecedence).map { -$0 }
        }

        if characters[index] == "+" {
            index += 1
            return parseUnary()
        }

        return parsePostfix()
    }

    /// A value, then whatever follows it that changes it: `20%` on its own is
    /// `0.2`, and `(3)(4)` is not multiplication by juxtaposition, which only
    /// ever surprises people.
    private mutating func parsePostfix() -> Double? {
        guard var value = parsePrimary() else {
            return nil
        }

        skipWhitespace()

        guard !suppressesPercent, index < characters.count, characters[index] == "%" else {
            return value
        }

        let saved = index
        index += 1
        skipWhitespace()

        // Followed by a word such as `of`, the percentage is a share of what
        // comes next: `20% of 45` is 9.
        if matchWord("of") {
            guard let whole = parseExpression(minimumPrecedence: 2) else {
                index = saved
                return value
            }

            return value / 100 * whole
        }

        // With a value after it the sign is a remainder, not a percentage:
        // `10 % 3` is 1, and only `20%` on its own is a fifth.
        if index < characters.count, startsValue(characters[index]) {
            index = saved
            return value
        }

        return value / 100
    }

    private mutating func parsePrimary() -> Double? {
        skipWhitespace()

        guard index < characters.count else {
            return nil
        }

        if characters[index] == "(" {
            index += 1

            guard let value = parseExpression(minimumPrecedence: 0) else {
                return nil
            }

            skipWhitespace()

            guard index < characters.count, characters[index] == ")" else {
                return nil
            }

            index += 1
            return value
        }

        if characters[index].isNumber || characters[index] == "." {
            return parseNumber()
        }

        if characters[index].isLetter {
            return parseNameOrCall()
        }

        return nil
    }

    private mutating func parseNumber() -> Double? {
        var digits = ""

        while index < characters.count {
            let character = characters[index]

            // `1_000_000` and `1,000,000` are both how people write a million.
            if character.isNumber || character == "." {
                digits.append(character)
                index += 1
                continue
            }

            if character == "_" {
                index += 1
                continue
            }

            // A comma only groups digits when it groups them in threes:
            // `1,234` is a number, while the comma in `log(2,8)` separates
            // two arguments and reading it as `28` gave a quietly wrong
            // answer rather than an error.
            if character == ",", groupsThousands(at: index) {
                index += 1
                continue
            }

            break
        }

        return Double(digits)
    }

    /// A constant, or a function applied to what follows it. `sqrt 100` and
    /// `sqrt(100)` are the same thing; anything taking more than one argument
    /// needs the parentheses and commas to say where each one ends.
    private mutating func parseNameOrCall() -> Double? {
        var name = ""

        while index < characters.count, characters[index].isLetter || characters[index].isNumber {
            name.append(characters[index])
            index += 1
        }

        let lowercased = name.lowercased()

        if let constant = Self.constants[lowercased] {
            return constant
        }

        guard let function = Self.functions[lowercased] else {
            return nil
        }

        skipWhitespace()

        if index < characters.count, characters[index] == "(" {
            index += 1
            var arguments: [Double] = []

            repeat {
                guard let argument = parseExpression(minimumPrecedence: 0) else {
                    return nil
                }

                arguments.append(argument)
                skipWhitespace()
            } while consumeIfPresent(",")

            guard index < characters.count, characters[index] == ")" else {
                return nil
            }

            index += 1
            return function(arguments)
        }

        // Without parentheses it takes one argument, and binds tighter than
        // any operator: `sqrt 16 + 9` is 13, not 5.
        guard let argument = parseUnary() else {
            return nil
        }

        return function([argument])
    }

    private static let constants: [String: Double] = [
        "pi": .pi,
        "e": M_E,
        "tau": .pi * 2,
    ]

    private static let functions: [String: @Sendable ([Double]) -> Double?] = [
        "sqrt": single(sqrt),
        "cbrt": single(cbrt),
        "abs": single(abs),
        "round": single { $0.rounded() },
        "floor": single(floor),
        "ceil": single(ceil),
        "ln": single(log),
        "log": { arguments in
            // One argument is the common log, two is log to a base, the way
            // a calculator and a maths textbook respectively mean it.
            switch arguments.count {
            case 1:
                return log10(arguments[0])
            case 2:
                return log(arguments[1]) / log(arguments[0])
            default:
                return nil
            }
        },
        "log2": single(log2),
        "log10": single(log10),
        "exp": single(exp),
        "sin": single(sin),
        "cos": single(cos),
        "tan": single(tan),
        "asin": single(asin),
        "acos": single(acos),
        "atan": single(atan),
        "min": { $0.count >= 2 ? $0.min() : nil },
        "max": { $0.count >= 2 ? $0.max() : nil },
    ]

    private static func single(
        _ body: @escaping @Sendable (Double) -> Double
    ) -> @Sendable ([Double]) -> Double? {
        { arguments in
            arguments.count == 1 ? body(arguments[0]) : nil
        }
    }

    private mutating func peekOperator() -> String? {
        skipWhitespace()

        guard index < characters.count else {
            return nil
        }

        if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "*" {
            return "**"
        }

        let character = String(characters[index])

        return Self.precedence[character] == nil ? nil : character
    }

    private mutating func consume(_ count: Int) {
        index += count
    }

    private mutating func consumeIfPresent(_ character: Character) -> Bool {
        skipWhitespace()

        guard index < characters.count, characters[index] == character else {
            return false
        }

        index += 1
        return true
    }

    private mutating func matchWord(_ word: String) -> Bool {
        let saved = index
        var read = ""

        while index < characters.count, characters[index].isLetter {
            read.append(characters[index])
            index += 1
        }

        guard read.lowercased() == word else {
            index = saved
            return false
        }

        return true
    }

    /// Three digits after the comma, and no fourth: what a thousands
    /// separator always looks like.
    private func groupsThousands(at position: Int) -> Bool {
        let digits = position + 1 ..< position + 4

        guard digits.upperBound <= characters.count,
              digits.allSatisfy({ characters[$0].isNumber }) else {
            return false
        }

        return digits.upperBound >= characters.count || !characters[digits.upperBound].isNumber
    }

    private func startsValue(_ character: Character) -> Bool {
        character.isNumber || character.isLetter || character == "(" || character == "."
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }
}
