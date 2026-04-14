#!/usr/bin/env swift

// validate_grapheme_cluster.swift
// Step 1: GraphemeCluster data structure validation
// 验证 GraphemeCluster 数据结构是否正确支持多 scalar emoji 序列

import Foundation

// MARK: - Test Helpers

struct TestResult {
    let name: String
    let passed: Bool
    let message: String
}

var results: [TestResult] = []

func expect(_ name: String, _ condition: Bool, _ message: String) {
    results.append(TestResult(name: name, passed: condition, message: message))
}

// MARK: - GraphemeCluster Definition (inline copy for standalone execution)

public struct GraphemeCluster: Equatable, Sendable, Hashable {
    public static let inlineCapacity = 4
    internal var _storage: (UInt32, UInt32, UInt32, UInt32)
    internal var _count: UInt8
    internal var _isHeapAllocated: Bool
    internal var _heapStorage: [UInt32]?
    
    public init() {
        self._storage = (0, 0, 0, 0)
        self._count = 0
        self._isHeapAllocated = false
        self._heapStorage = nil
    }
    
    public init(_ scalar: Unicode.Scalar) {
        self._storage = (scalar.value, 0, 0, 0)
        self._count = 1
        self._isHeapAllocated = false
        self._heapStorage = nil
    }
    
    public init(_ character: Character) {
        let scalars = Array(character.unicodeScalars)
        self._count = UInt8(clamping: scalars.count)
        self._isHeapAllocated = scalars.count > Self.inlineCapacity
        self._heapStorage = self._isHeapAllocated ? scalars.map { $0.value } : nil
        
        if !self._isHeapAllocated {
            self._storage = (
                scalars.count > 0 ? scalars[0].value : 0,
                scalars.count > 1 ? scalars[1].value : 0,
                scalars.count > 2 ? scalars[2].value : 0,
                scalars.count > 3 ? scalars[3].value : 0
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
        
        if _isHeapAllocated, let heap = _heapStorage {
            for value in heap {
                if let scalar = Unicode.Scalar(value) {
                    result.append(scalar)
                }
            }
        } else {
            let values = [_storage.0, _storage.1, _storage.2, _storage.3]
            for i in 0..<min(Int(_count), Self.inlineCapacity) {
                if let scalar = Unicode.Scalar(values[i]) {
                    result.append(scalar)
                }
            }
        }
        return result
    }
    
    public var firstScalar: Unicode.Scalar? {
        if _count == 0 { return nil }
        let value: UInt32
        if _isHeapAllocated, let heap = _heapStorage, !heap.isEmpty {
            value = heap[0]
        } else {
            value = _storage.0
        }
        return Unicode.Scalar(value)
    }
    
    public var isEmojiSequence: Bool {
        if _count <= 1 { return false }
        let values: [UInt32]
        if _isHeapAllocated, let heap = _heapStorage {
            values = heap
        } else {
            let inline = [_storage.0, _storage.1, _storage.2, _storage.3]
            values = Array(inline.prefix(Int(_count)))
        }
        for v in values {
            if v == 0x200D ||
               v == 0xFE0E || v == 0xFE0F ||
               (v >= 0x1F3FB && v <= 0x1F3FF) ||
               (v >= 0x1F1E6 && v <= 0x1F1FF) ||
               (v >= 0xE0020 && v <= 0xE007F) {
                return true
            }
        }
        return false
    }
    
    public var string: String {
        var result = ""
        for scalar in scalars {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
    
    public static func == (lhs: GraphemeCluster, rhs: GraphemeCluster) -> Bool {
        guard lhs._count == rhs._count else { return false }
        if lhs._isHeapAllocated {
            return lhs._heapStorage == rhs._heapStorage
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
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_count)
        if _isHeapAllocated, let heap = _heapStorage {
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

// MARK: - Tests

print(String(repeating: "=", count: 60))
print("Step 1: GraphemeCluster Data Structure Validation")
print(String(repeating: "=", count: 60))

// 1. ZWJ Sequence: 👨‍👩‍👧‍👦
let family = GraphemeCluster("👨‍👩‍👧‍👦")
expect("ZWJ Sequence scalar count",
       family.scalarCount == 7,
       "👨‍👩‍👧‍👦 should have 7 scalars, got \(family.scalarCount)")
expect("ZWJ Sequence is emoji sequence",
       family.isEmojiSequence,
       "👨‍👩‍👧‍👦 should be detected as emoji sequence")

// 2. Skin tone modifier: 👋🏻
let wave = GraphemeCluster("👋🏻")
expect("Skin Tone scalar count",
       wave.scalarCount == 2,
       "👋🏻 should have 2 scalars, got \(wave.scalarCount)")
expect("Skin Tone is emoji sequence",
       wave.isEmojiSequence,
       "👋🏻 should be detected as emoji sequence")

// 3. Flag emoji: 🇨🇳
let flag = GraphemeCluster("🇨🇳")
expect("Flag scalar count",
       flag.scalarCount == 2,
       "🇨🇳 should have 2 scalars, got \(flag.scalarCount)")
expect("Flag is emoji sequence",
       flag.isEmojiSequence,
       "🇨🇳 should be detected as emoji sequence")

// 4. Simple ASCII
let letterA = GraphemeCluster(Character("A"))
expect("ASCII scalar count",
       letterA.scalarCount == 1,
       "'A' should have 1 scalar, got \(letterA.scalarCount)")
expect("ASCII is not emoji sequence",
       !letterA.isEmojiSequence,
       "'A' should not be detected as emoji sequence")

// 5. Single emoji
let smiley = GraphemeCluster(Character("😀"))
expect("Single emoji scalar count",
       smiley.scalarCount == 1,
       "😀 should have 1 scalar, got \(smiley.scalarCount)")
expect("Single emoji is not multi-scalar sequence",
       !smiley.isEmojiSequence,
       "😀 should not be detected as emoji sequence (only 1 scalar)")

// 6. String round-trip
expect("ZWJ string round-trip",
       family.string == "👨‍👩‍👧‍👦",
       "String round-trip failed for 👨‍👩‍👧‍👦")
expect("Flag string round-trip",
       flag.string == "🇨🇳",
       "String round-trip failed for 🇨🇳")

// 7. First scalar
expect("ZWJ first scalar",
       family.firstScalar == Unicode.Scalar(0x1F468),
       "First scalar of 👨‍👩‍👧‍👦 should be U+1F468")
expect("Flag first scalar",
       flag.firstScalar == Unicode.Scalar(0x1F1E8),
       "First scalar of 🇨🇳 should be U+1F1E8")

// 8. Equatable
let family2 = GraphemeCluster("👨‍👩‍👧‍👦")
expect("Equatable",
       family == family2,
       "Two identical GraphemeClusters should be equal")

// MARK: - Results

let passed = results.filter(\.passed).count
let failed = results.filter { !$0.passed }.count

print("\nTest Results:")
for result in results {
    let icon = result.passed ? "✅" : "❌"
    print("  \(icon) \(result.name): \(result.passed ? "PASS" : "FAIL")")
    if !result.passed {
        print("     \(result.message)")
    }
}

print("\n" + String(repeating: "=", count: 60))
print("Total: \(passed) passed, \(failed) failed out of \(results.count) tests")

if failed > 0 {
    print("❌ Step 1 FAILED")
    exit(1)
} else {
    print("✅ Step 1 PASSED: GraphemeCluster data structure is working correctly")
}
