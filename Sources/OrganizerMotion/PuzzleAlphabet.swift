public enum PuzzleAlphabet {
    public static let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    public static let symbols = Array("!?.,:;…+-=*/\\%()[]{}<>#@&_\"'`^|~$×÷")
    public static let supportedCharacters = characters + symbols
    public static let spacing = 1
    public static let height = 6

    /// Retains the existing TILE face; wide diagonals get five columns.
    private static let glyphs: [Character: [String]] = [
        "A": ["010", "101", "111", "101", "101"],
        "B": ["110", "101", "110", "101", "110"],
        "C": ["111", "100", "100", "100", "111"],
        "D": ["110", "101", "101", "101", "110"],
        "E": ["111", "100", "111", "100", "111"],
        "F": ["111", "100", "111", "100", "100"],
        "G": ["111", "100", "101", "101", "111"],
        "H": ["101", "101", "111", "101", "101"],
        "I": ["111", "010", "010", "010", "111"],
        "J": ["001", "001", "001", "101", "111"],
        "K": ["101", "101", "110", "101", "101"],
        "L": ["100", "100", "100", "100", "111"],
        "M": ["10001", "11011", "10101", "10001", "10001"],
        "N": ["10001", "11001", "10101", "10011", "10001"],
        "O": ["111", "101", "101", "101", "111"],
        "P": ["111", "101", "111", "100", "100"],
        "Q": ["01110", "10001", "10101", "10010", "01101"],
        "R": ["110", "101", "110", "101", "101"],
        "S": ["111", "100", "111", "001", "111"],
        "T": ["111", "010", "010", "010", "010"],
        "U": ["101", "101", "101", "101", "111"],
        "V": ["101", "101", "101", "101", "010"],
        "W": ["10001", "10001", "10101", "10101", "01010"],
        "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"],
        "Z": ["111", "001", "010", "100", "111"],
        "0": ["010", "101", "101", "101", "010"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
        "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"],
        "9": ["111", "101", "111", "001", "111"],
        " ": ["00", "00", "00", "00", "00"],
        "!": ["1", "1", "1", "0", "1"],
        "?": ["110", "001", "010", "000", "010"],
        ".": ["0", "0", "0", "0", "1"],
        ",": ["00", "00", "00", "01", "10"],
        ":": ["0", "1", "0", "1", "0"],
        ";": ["00", "01", "00", "01", "10"],
        "…": ["00000", "00000", "00000", "00000", "10101"],
        "+": ["000", "010", "111", "010", "000"],
        "-": ["000", "000", "111", "000", "000"],
        "=": ["000", "111", "000", "111", "000"],
        "*": ["101", "010", "111", "010", "101"],
        "/": ["001", "001", "010", "100", "100"],
        "\\": ["100", "100", "010", "001", "001"],
        "%": ["11001", "11010", "00100", "01011", "10011"],
        "(": ["01", "10", "10", "10", "01"],
        ")": ["10", "01", "01", "01", "10"],
        "[": ["11", "10", "10", "10", "11"],
        "]": ["11", "01", "01", "01", "11"],
        "{": ["011", "010", "100", "010", "011"],
        "}": ["110", "010", "001", "010", "110"],
        "<": ["001", "010", "100", "010", "001"],
        ">": ["100", "010", "001", "010", "100"],
        "#": ["01010", "11111", "01010", "11111", "01010"],
        "@": ["01110", "10001", "10111", "10101", "01111"],
        "&": ["01100", "10010", "01100", "10101", "10010", "01101"],
        "_": ["000", "000", "000", "000", "111"],
        "\"": ["101", "101", "000", "000", "000"],
        "'": ["1", "1", "0", "0", "0"],
        "`": ["10", "01", "00", "00", "00"],
        "^": ["010", "101", "000", "000", "000"],
        "|": ["1", "1", "1", "1", "1"],
        "~": ["00000", "01000", "10101", "00010", "00000"],
        "$": ["00100", "01111", "10100", "01110", "00101", "11110"],
        "×": ["000", "101", "010", "101", "000"],
        "÷": ["010", "000", "111", "000", "010"]
    ]

    private static let aliases: [Character: Character] = [
        "—": "-", "–": "-", "−": "-",
        "‘": "'", "’": "'", "“": "\"", "”": "\"",
        "！": "!", "？": "?"
    ]

    public enum Error: Swift.Error, Equatable {
        case unsupportedCharacter(Character)
        case textTooWide(required: Int, available: Int)
        case invalidCanvas
        case emptyText
    }

    /// Lowercase ASCII uses uppercase tiles; typographic variants share a face.
    public static func normalized(_ text: String) throws -> String {
        try String(text.map { character in
            let canonical = aliases[character] ?? character
            let upper: Character
            if let value = canonical.asciiValue, (97...122).contains(value) {
                upper = Character(UnicodeScalar(value - 32))
            } else {
                upper = canonical
            }
            guard glyphs[upper] != nil else { throw Error.unsupportedCharacter(character) }
            return upper
        })
    }

    public static func width(of text: String) throws -> Int {
        let characters = Array(try normalized(text))
        return characters.reduce(0) { $0 + glyphs[$1]![0].count }
            + max(0, characters.count - 1) * spacing
    }

    public static func cells(for text: String) throws -> [TileWordmarkMotion.Cell] {
        let text = try normalized(text)
        var result: [TileWordmarkMotion.Cell] = []
        var offset = 0
        for character in text {
            let pattern = glyphs[character]!
            for (row, line) in pattern.enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    result.append(.init(offset + column, row + height - pattern.count))
                }
            }
            offset += pattern[0].count + spacing
        }
        return result
    }
}
