/// A grapheme cluster representing one or more Unicode scalars that form
/// a single visual character (e.g., emoji sequences with ZWJ, skin tones, etc.).
///
/// Uses inline storage for up to 4 scalars (covers most emoji sequences),
/// falling back to heap allocation for longer sequences.
public struct GraphemeCluster: Equatable, Sendable, Hashable {
    public static let inlineCapacity = 4
    public static let maxScalarCount: UInt8 = 32
    
    private var _storage: (UInt32, UInt32, UInt32, UInt32)
    private var _count: UInt8
    private var _heapStorage: [UInt32]?
    
    private var _isHeapAllocated: Bool {
        _count > Self.inlineCapacity
    }
    
    public init() {
        self._storage = (0, 0, 0, 0)
        self._count = 0
        self._heapStorage = nil
    }
    
    public init(_ scalar: Unicode.Scalar) {
        self._storage = (scalar.value, 0, 0, 0)
        self._count = 1
        self._heapStorage = nil
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
                count > 1 ? scalars[1].value : 0,
                count > 2 ? scalars[2].value : 0,
                count > 3 ? scalars[3].value : 0
            )
        } else {
            self._storage = (0, 0, 0, 0)
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
            if count > 2, let s = Unicode.Scalar(_storage.2) { result.append(s) }
            if count > 3, let s = Unicode.Scalar(_storage.3) { result.append(s) }
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
    
    public var isEmojiSequence: Bool {
        if _count <= 1 { return false }
        return _checkForEmojiMarkers()
    }

    public var isEmojiContent: Bool {
        if isEmojiSequence { return true }
        return firstScalar?.isEmojiScalar ?? false
    }

    private func _checkForEmojiMarkers() -> Bool {
        func checkValue(_ v: UInt32) -> Bool {
            v == 0x200D ||
            v == 0xFE0E || v == 0xFE0F ||
            (v >= 0x1F3FB && v <= 0x1F3FF) ||
            (v >= 0x1F1E6 && v <= 0x1F1FF) ||
            (v >= 0xE0020 && v <= 0xE007F)
        }

        if let heap = _heapStorage {
            for v in heap {
                if checkValue(v) { return true }
            }
        } else {
            let count = min(Int(_count), Self.inlineCapacity)
            if count > 0 && checkValue(_storage.0) { return true }
            if count > 1 && checkValue(_storage.1) { return true }
            if count > 2 && checkValue(_storage.2) { return true }
            if count > 3 && checkValue(_storage.3) { return true }
        }
        return false
    }
    
    public var terminalWidth: UInt8 {
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
            if count > 2, let s = Unicode.Scalar(_storage.2) { result.unicodeScalars.append(s) }
            if count > 3, let s = Unicode.Scalar(_storage.3) { result.unicodeScalars.append(s) }
        }
        return result
    }
}

extension GraphemeCluster {
    public static func == (lhs: GraphemeCluster, rhs: GraphemeCluster) -> Bool {
        guard lhs._count == rhs._count else { return false }
        
        if let leftHeap = lhs._heapStorage, let rightHeap = rhs._heapStorage {
            return leftHeap == rightHeap
        }
        
        switch lhs._count {
        case 0: return true
        case 1: return lhs._storage.0 == rhs._storage.0
        case 2: return lhs._storage.0 == rhs._storage.0 && lhs._storage.1 == rhs._storage.1
        case 3: return lhs._storage.0 == rhs._storage.0 && lhs._storage.1 == rhs._storage.1 && lhs._storage.2 == rhs._storage.2
        case 4: return lhs._storage.0 == rhs._storage.0 && lhs._storage.1 == rhs._storage.1 && lhs._storage.2 == rhs._storage.2 && lhs._storage.3 == rhs._storage.3
        default: return false
        }
    }
}

extension GraphemeCluster {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_count)
        if let heap = _heapStorage {
            hasher.combine(heap)
        } else {
            switch _count {
            case 1: hasher.combine(_storage.0)
            case 2: hasher.combine(_storage.0); hasher.combine(_storage.1)
            case 3: hasher.combine(_storage.0); hasher.combine(_storage.1); hasher.combine(_storage.2)
            case 4: hasher.combine(_storage.0); hasher.combine(_storage.1); hasher.combine(_storage.2); hasher.combine(_storage.3)
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
