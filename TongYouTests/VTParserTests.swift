import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite struct VTParserTests {

    // MARK: - Helpers

    private func parse(_ bytes: [UInt8]) -> [VTAction] {
        var parser = VTParser()
        var actions: [VTAction] = []
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in
                actions.append(action)
            }
        }
        return actions
    }

    private func parseString(_ s: String) -> [VTAction] {
        parse(Array(s.utf8))
    }

    // MARK: - Ground State

    @Test func printableASCII() {
        let actions = parseString("A")
        #expect(actions.count == 1)
        if case .print(let scalar) = actions[0] {
            #expect(scalar == "A")
        } else {
            Issue.record("Expected .print, got \(actions[0])")
        }
    }

    @Test func multipleASCII() {
        let actions = parseString("Hi")
        #expect(actions.count == 1)
        if case .printBatch(let count, let buffer) = actions[0] {
            #expect(count == 2)
            #expect(buffer[0] == 0x48) // 'H'
            #expect(buffer[1] == 0x69) // 'i'
        } else {
            Issue.record("Expected .printBatch, got \(actions[0])")
        }
    }

    @Test func utf8TwoByteCharacter() {
        // é = 0xC3 0xA9
        let actions = parse([0xC3, 0xA9])
        #expect(actions.count == 1)
        if case .print(let scalar) = actions[0] {
            #expect(scalar == "\u{00E9}")
        } else {
            Issue.record("Expected .print, got \(actions[0])")
        }
    }

    @Test func utf8ThreeByteCharacter() {
        // 中 = 0xE4 0xB8 0xAD
        let actions = parse([0xE4, 0xB8, 0xAD])
        #expect(actions.count == 1)
        if case .print(let scalar) = actions[0] {
            #expect(scalar == "\u{4E2D}")
        } else {
            Issue.record("Expected .print, got \(actions[0])")
        }
    }

    // MARK: - C0 Control Characters

    @Test func c0ControlCodes() {
        let actions = parse([0x0A]) // LF
        #expect(actions.count == 1)
        if case .execute(let byte) = actions[0] {
            #expect(byte == 0x0A)
        } else {
            Issue.record("Expected .execute, got \(actions[0])")
        }
    }

    @Test func bellCharacter() {
        let actions = parse([0x07])
        #expect(actions.count == 1)
        if case .execute(let byte) = actions[0] {
            #expect(byte == 0x07)
        } else {
            Issue.record("Expected .execute, got \(actions[0])")
        }
    }

    // MARK: - CSI Sequences

    @Test func csiNoParams() {
        // ESC [ H (CUP with no params)
        let actions = parse([0x1B, 0x5B, 0x48])
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x48) // 'H'
            #expect(params.count == 0)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiTwoParams() {
        // ESC [ 1 ; 4 H (CUP row=1, col=4)
        let actions = parse([0x1B, 0x5B, 0x31, 0x3B, 0x34, 0x48])
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x48) // 'H'
            #expect(params.count == 2)
            #expect(params[0] == 1)
            #expect(params[1] == 4)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiPrivateMode() {
        // ESC [ ? 25 h (DECTCEM - show cursor)
        let actions = parse([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68])
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x68) // 'h'
            #expect(params.hasIntermediate(0x3F)) // '?'
            #expect(params.count == 1)
            #expect(params[0] == 25)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiSGR() {
        // ESC [ 1 ; 31 m (bold + red foreground)
        let actions = parseString("\u{1B}[1;31m")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x6D) // 'm'
            #expect(params.count == 2)
            #expect(params[0] == 1)
            #expect(params[1] == 31)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiSGRWithColon() {
        // ESC [ 38 : 2 : 255 : 0 : 0 m (TrueColor red fg with colon separators)
        let actions = parseString("\u{1B}[38:2:255:0:0m")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x6D) // 'm'
            #expect(params.count == 5)
            #expect(params[0] == 38)
            #expect(params[1] == 2)
            #expect(params[2] == 255)
            #expect(params[3] == 0)
            #expect(params[4] == 0)
            #expect(params.isColon(at: 0))
            #expect(params.isColon(at: 1))
            #expect(params.isColon(at: 2))
            #expect(params.isColon(at: 3))
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiColonOnlyAllowedForSGR() {
        // ESC [ 38 : 2 H — colon with non-'m' final should be rejected
        let actions = parseString("\u{1B}[38:2H")
        #expect(actions.count == 0) // rejected
    }

    @Test func csiMultipleSequences() {
        // ESC[H ESC[2J — two CSI sequences back to back
        let actions = parseString("\u{1B}[H\u{1B}[2J")
        #expect(actions.count == 2)
        if case .csiDispatch(let p1) = actions[0] {
            #expect(p1.finalByte == 0x48) // 'H'
        }
        if case .csiDispatch(let p2) = actions[1] {
            #expect(p2.finalByte == 0x4A) // 'J'
            #expect(p2.count == 1)
            #expect(p2[0] == 2)
        }
    }

    @Test func csiDefaultParam() {
        // ESC [ m (SGR reset — no params, defaults to 0)
        let actions = parseString("\u{1B}[m")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x6D)
            #expect(params.count == 0)
            // Caller should treat no params as default 0
            #expect(params.param(0, default: 0) == 0)
        }
    }

    // MARK: - ESC Sequences

    @Test func escSequenceSimple() {
        // ESC c (RIS - full reset)
        let actions = parse([0x1B, 0x63])
        #expect(actions.count == 1)
        if case .escDispatch(let final, let imCount, _) = actions[0] {
            #expect(final == 0x63) // 'c'
            #expect(imCount == 0)
        } else {
            Issue.record("Expected .escDispatch, got \(actions[0])")
        }
    }

    @Test func escSequenceWithIntermediate() {
        // ESC ( B (select character set)
        let actions = parse([0x1B, 0x28, 0x42])
        #expect(actions.count == 1)
        if case .escDispatch(let final, let imCount, let im) = actions[0] {
            #expect(final == 0x42) // 'B'
            #expect(imCount == 1)
            #expect(im.0 == 0x28)
        } else {
            Issue.record("Expected .escDispatch, got \(actions[0])")
        }
    }

    // MARK: - OSC Sequences

    @Test func oscWindowTitle() {
        // ESC ] 0 ; title BEL
        let actions = parseString("\u{1B}]0;Hello World\u{07}")
        #expect(actions.count == 1)
        if case .oscDispatch(let data) = actions[0] {
            let str = String(bytes: data, encoding: .utf8)
            #expect(str == "0;Hello World")
        } else {
            Issue.record("Expected .oscDispatch, got \(actions[0])")
        }
    }

    @Test func oscTerminatedByST() {
        // ESC ] 2 ; title ESC \ (ST terminator)
        // ESC causes oscString→escape transition (emits oscDispatch),
        // then '\' in escape dispatches as escDispatch.
        let actions = parseString("\u{1B}]2;Title\u{1B}\\")
        #expect(actions.count == 2)
        if case .oscDispatch(let data) = actions[0] {
            let str = String(bytes: data, encoding: .utf8)
            #expect(str == "2;Title")
        } else {
            Issue.record("Expected .oscDispatch, got \(actions[0])")
        }
        // The ESC \ produces an escDispatch with final '\' (0x5C)
        if case .escDispatch(let final, _, _) = actions[1] {
            #expect(final == 0x5C)
        }
    }

    // MARK: - Mixed Sequences

    @Test func textWithEscapeSequences() {
        // "A" ESC[31m "B" — print, SGR, print
        let actions = parseString("A\u{1B}[31mB")
        #expect(actions.count == 3)
        if case .print(let s) = actions[0] { #expect(s == "A") }
        if case .csiDispatch(let p) = actions[1] {
            #expect(p.finalByte == 0x6D)
            #expect(p.count == 1)
            #expect(p[0] == 31)
        }
        if case .print(let s) = actions[2] { #expect(s == "B") }
    }

    @Test func controlCodesInterleaved() {
        // LF CR mixed with print
        let actions = parse([0x41, 0x0A, 0x0D, 0x42])
        #expect(actions.count == 4)
        if case .print(let s) = actions[0] { #expect(s == "A") }
        if case .execute(let b) = actions[1] { #expect(b == 0x0A) }
        if case .execute(let b) = actions[2] { #expect(b == 0x0D) }
        if case .print(let s) = actions[3] { #expect(s == "B") }
    }

    // MARK: - CSI Fast Path

    @Test func csiFastPathSGR() {
        // ESC [ 1 ; 31 m via fast path
        let actions = parseString("\u{1B}[1;31m")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x6D)
            #expect(params.count == 2)
            #expect(params[0] == 1)
            #expect(params[1] == 31)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiFastPathCUP() {
        // ESC [ 10 ; 20 H via fast path
        let actions = parseString("\u{1B}[10;20H")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x48)
            #expect(params.count == 2)
            #expect(params[0] == 10)
            #expect(params[1] == 20)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiFastPathEL() {
        // ESC [ 2 K via fast path
        let actions = parseString("\u{1B}[2K")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x4B)
            #expect(params.count == 1)
            #expect(params[0] == 2)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiFastPathFallbackOnIntermediate() {
        // ESC [ ? 25 h — has '?' intermediate, fast path should bail to state machine
        let actions = parseString("\u{1B}[?25h")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x68) // 'h'
            #expect(params.hasIntermediate(0x3F)) // '?'
            #expect(params.count == 1)
            #expect(params[0] == 25)
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    @Test func csiFastPathFallbackOnColon() {
        // ESC [ 38 : 2 : 255 m — has colons, fast path should bail to state machine
        let actions = parseString("\u{1B}[38:2:255m")
        #expect(actions.count == 1)
        if case .csiDispatch(let params) = actions[0] {
            #expect(params.finalByte == 0x6D) // 'm'
            #expect(params.count == 3)
            #expect(params.isColon(at: 0))
        } else {
            Issue.record("Expected .csiDispatch, got \(actions[0])")
        }
    }

    // MARK: - Print Batching

    @Test func printBatchFlushBeforeCSI() {
        // "Hello" ESC[m — batch flush before CSI
        let actions = parseString("Hello\u{1B}[m")
        #expect(actions.count == 2)
        if case .printBatch(let count, let buffer) = actions[0] {
            #expect(count == 5)
            #expect(buffer[0] == 0x48) // 'H'
            #expect(buffer[4] == 0x6F) // 'o'
        } else {
            Issue.record("Expected .printBatch, got \(actions[0])")
        }
        if case .csiDispatch(let params) = actions[1] {
            #expect(params.finalByte == 0x6D) // 'm'
        }
    }

    @Test func printBatchFlushBeforeControl() {
        // "AB" LF "CD" — two batches separated by control
        let actions = parseString("AB\nCD")
        #expect(actions.count == 3)
        if case .printBatch(let count, _) = actions[0] {
            #expect(count == 2)
        } else {
            Issue.record("Expected .printBatch for AB, got \(actions[0])")
        }
        if case .execute(let b) = actions[1] {
            #expect(b == 0x0A)
        }
        if case .printBatch(let count, _) = actions[2] {
            #expect(count == 2)
        } else {
            Issue.record("Expected .printBatch for CD, got \(actions[2])")
        }
    }

    // MARK: - Invalid / Recovery

    @Test func invalidCSIRecovery() {
        // An invalid CSI (incomplete) followed by valid text
        // ESC [ then ESC (the second ESC cancels the CSI)
        let actions = parse([0x1B, 0x5B, 0x1B, 0x63])
        // Should get: escDispatch for ESC c (the CSI was cancelled by ESC)
        #expect(actions.count == 1)
        if case .escDispatch(let final, _, _) = actions[0] {
            #expect(final == 0x63)
        }
    }

    // MARK: - CSIParams

    @Test func csiParamsAccess() {
        var params = CSIParams()
        params.finalizeParam(10)
        params.finalizeParam(20)
        params.finalizeParam(30)
        #expect(params.count == 3)
        #expect(params[0] == 10)
        #expect(params[1] == 20)
        #expect(params[2] == 30)
        #expect(params.param(0, default: 1) == 10)
        #expect(params.param(5, default: 99) == 99)
    }

    @Test func csiParamsDefaultForZero() {
        var params = CSIParams()
        params.finalizeParam(0)
        // param() with default should return default when stored value is 0
        #expect(params.param(0, default: 1) == 1)
        // Direct access returns 0
        #expect(params[0] == 0)
    }

    @Test func csiParamsIntermediates() {
        var params = CSIParams()
        params.addIntermediate(0x3F) // '?'
        params.addIntermediate(0x20) // ' '
        #expect(params.intermediateCount == 2)
        #expect(params.intermediate(0) == 0x3F)
        #expect(params.intermediate(1) == 0x20)
        #expect(params.hasIntermediate(0x3F))
        #expect(!params.hasIntermediate(0x21))
    }
}
