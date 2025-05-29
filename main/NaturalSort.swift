enum NaturalSortComponent: Comparable {
    case number(Int)
    case text(String)

    static func < (lhs: NaturalSortComponent, rhs: NaturalSortComponent) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            return a < b
        case let (.text(a), .text(b)):
            return a < b
        case (.number, .text):
            return true
        case (.text, .number):
            return false
        }
    }
}

extension String {
    func naturalSortComponents() -> [NaturalSortComponent] {
        var comps: [NaturalSortComponent] = []
        var current = ""
        var isCurrentDigit: Bool? = nil

        for ch in self {
            let digit = ch.isWholeNumber
            if isCurrentDigit == nil {
                current.append(ch)
                isCurrentDigit = digit
            } else if digit == isCurrentDigit {
                current.append(ch)
            } else {
                if let wasDigit = isCurrentDigit {
                    if wasDigit, let n = Int(current) {
                        comps.append(.number(n))
                    } else {
                        comps.append(.text(current))
                    }
                }
                current = String(ch)
                isCurrentDigit = digit
            }
        }
        if let wasDigit = isCurrentDigit {
            if wasDigit, let n = Int(current) {
                comps.append(.number(n))
            } else {
                comps.append(.text(current))
            }
        }
        return comps
    }
}

func naturalSort(_ a: String, _ b: String) -> Bool {
    let ac = a.naturalSortComponents()
    let bc = b.naturalSortComponents()
    return ac.lexicographicallyPrecedes(bc)
}
