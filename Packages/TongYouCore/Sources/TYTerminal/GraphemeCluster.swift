/// Presentation style for a character: text (monochrome) or emoji (color).
public enum Presentation: UInt8, Equatable, Sendable {
    case text = 0   // U+FE0E (VS15) or default text presentation
    case emoji = 1  // U+FE0F (VS16) or default emoji presentation
}

/// A grapheme cluster representing one or more Unicode scalars that form
/// a single visual character (e.g., emoji sequences with ZWJ, skin tones, etc.).
///
/// Uses inline storage for up to 2 scalars (covers ASCII, CJK, flag emoji,
/// skin-tone emoji), falling back to heap allocation for longer sequences
/// like ZWJ families. Optimized for terminal use where 99%+ of characters
/// are single-scalar.
public struct GraphemeCluster: Equatable, Sendable, Hashable {
    public static let inlineCapacity = 2
    public static let maxScalarCount: UInt8 = 32

    private var _storage: (UInt32, UInt32)
    private var _count: UInt8
    private var _heapStorage: [UInt32]?
    /// Explicit presentation from variation selector: 0=none, 1=text(VS15), 2=emoji(VS16).
    private var _explicitPresentation: UInt8

    private var _isHeapAllocated: Bool {
        _count > Self.inlineCapacity
    }

    public init() {
        self._storage = (0, 0)
        self._count = 0
        self._heapStorage = nil
        self._explicitPresentation = 0
    }

    public init(_ scalar: Unicode.Scalar) {
        self._storage = (scalar.value, 0)
        self._count = 1
        self._heapStorage = nil
        self._explicitPresentation = 0
    }

    public init(_ character: Character) {
        self.init(scalars: Array(character.unicodeScalars))
    }

    public init(scalars: [Unicode.Scalar]) {
        let count = min(scalars.count, Int(Self.maxScalarCount))
        self._count = UInt8(clamping: count)
        let isHeap = count > Self.inlineCapacity
        self._heapStorage = isHeap ? scalars.prefix(count).map { $0.value } : nil

        if !isHeap {
            self._storage = (
                count > 0 ? scalars[0].value : 0,
                count > 1 ? scalars[1].value : 0
            )
        } else {
            self._storage = (0, 0)
        }

        // Detect explicit presentation from variation selectors.
        self._explicitPresentation = 0
        for s in scalars.prefix(count) {
            if s.value == 0xFE0E { self._explicitPresentation = 1; break }
            if s.value == 0xFE0F { self._explicitPresentation = 2; break }
        }
    }
    
    public var scalarCount: Int {
        Int(_count)
    }
    
    public var scalars: [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalarCount)

        if let heap = _heapStorage {
            for value in heap {
                if let scalar = Unicode.Scalar(value) {
                    result.append(scalar)
                }
            }
        } else {
            let count = min(Int(_count), Self.inlineCapacity)
            if count > 0, let s = Unicode.Scalar(_storage.0) { result.append(s) }
            if count > 1, let s = Unicode.Scalar(_storage.1) { result.append(s) }
        }
        return result
    }
    
    public var firstScalar: Unicode.Scalar? {
        if _count == 0 { return nil }
        
        if let heap = _heapStorage, !heap.isEmpty {
            return Unicode.Scalar(heap[0])
        }
        return Unicode.Scalar(_storage.0)
    }
    
    /// Explicit presentation set by a variation selector, or nil if none.
    public var explicitPresentation: Presentation? {
        switch _explicitPresentation {
        case 1: return .text
        case 2: return .emoji
        default: return nil
        }
    }

    /// Resolved presentation: explicit VS if present, otherwise UCD default.
    /// Only characters with Emoji_Presentation=Yes default to emoji.
    /// Characters with Emoji=Yes but Emoji_Presentation=No (e.g. U+23FA)
    /// default to text and only become emoji with explicit VS16.
    public var resolvedPresentation: Presentation {
        if let explicit = explicitPresentation { return explicit }
        if isEmojiSequence { return .emoji }
        if let first = firstScalar, first.isEmojiPresentation { return .emoji }
        return .text
    }

    public var isEmojiSequence: Bool {
        if _count <= 1 { return false }
        return _checkForEmojiMarkers()
    }

    public var isEmojiContent: Bool {
        resolvedPresentation == .emoji
    }

    private func _checkForEmojiMarkers() -> Bool {
        func checkValue(_ v: UInt32) -> Bool {
            v == 0x200D ||      // ZWJ
            v == 0xFE0F ||      // VS16 (emoji presentation)
            (v >= 0x1F3FB && v <= 0x1F3FF) ||  // skin tones
            (v >= 0x1F1E6 && v <= 0x1F1FF) ||  // regional indicators
            (v >= 0xE0020 && v <= 0xE007F)     // tags
            // Note: 0xFE0E (VS15) is NOT an emoji marker — it forces text presentation.
        }

        if let heap = _heapStorage {
            for v in heap {
                if checkValue(v) { return true }
            }
        } else {
            let count = min(Int(_count), Self.inlineCapacity)
            if count > 0 && checkValue(_storage.0) { return true }
            if count > 1 && checkValue(_storage.1) { return true }
        }
        return false
    }
    
    public var terminalWidth: UInt8 {
        // Explicit VS16 forces wide (2), VS15 forces narrow (1).
        if let p = explicitPresentation {
            return p == .emoji ? 2 : 1
        }

        guard let first = firstScalar else { return 1 }

        if isEmojiSequence {
            return first.terminalWidth
        }

        if _count == 1 {
            return first.terminalWidth
        }

        var width: UInt8 = 0
        for scalar in scalars {
            width += scalar.terminalWidth
        }
        return max(1, width)
    }
    
    public var string: String {
        var result = ""
        result.unicodeScalars.reserveCapacity(scalarCount)

        if let heap = _heapStorage {
            for value in heap {
                if let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            }
        } else {
            let count = min(Int(_count), Self.inlineCapacity)
            if count > 0, let s = Unicode.Scalar(_storage.0) { result.unicodeScalars.append(s) }
            if count > 1, let s = Unicode.Scalar(_storage.1) { result.unicodeScalars.append(s) }
        }
        return result
    }
}

extension GraphemeCluster {
    public static func == (lhs: GraphemeCluster, rhs: GraphemeCluster) -> Bool {
        guard lhs._count == rhs._count else { return false }
        guard lhs._explicitPresentation == rhs._explicitPresentation else { return false }

        if let leftHeap = lhs._heapStorage, let rightHeap = rhs._heapStorage {
            return leftHeap == rightHeap
        }

        switch lhs._count {
        case 0: return true
        case 1: return lhs._storage.0 == rhs._storage.0
        case 2: return lhs._storage.0 == rhs._storage.0 && lhs._storage.1 == rhs._storage.1
        default: return false
        }
    }
}

extension GraphemeCluster {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_count)
        hasher.combine(_explicitPresentation)
        if let heap = _heapStorage {
            hasher.combine(heap)
        } else {
            switch _count {
            case 1: hasher.combine(_storage.0)
            case 2: hasher.combine(_storage.0); hasher.combine(_storage.1)
            default: break
            }
        }
    }
}

extension GraphemeCluster: ExpressibleByUnicodeScalarLiteral {
    public init(unicodeScalarLiteral value: Unicode.Scalar) {
        self.init(value)
    }
}

extension GraphemeCluster: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral value: Character) {
        self.init(value)
    }
}

extension GraphemeCluster: CustomStringConvertible {
    public var description: String {
        string
    }
}
