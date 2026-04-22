import Foundation
import Testing
@testable import TongYou

@Suite struct VTParserBenchmarkTests {

    // MARK: - Benchmark Helpers

    /// Measure throughput of parsing a byte buffer, returning bytes/second.
    private func measureThroughput(
        label: String,
        data: [UInt8],
        iterations: Int = 50
    ) -> Double {
        let totalBytes = data.count * iterations
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<iterations {
                var parser = VTParser()
                data.withUnsafeBufferPointer { ptr in
                    parser.feed(ptr) { _ in }
                }
            }
        }

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        let throughput = Double(totalBytes) / seconds
        let mbPerSec = throughput / (1024 * 1024)
        print("[\(label)] \(totalBytes) bytes in \(String(format: "%.3f", seconds * 1000))ms = \(String(format: "%.1f", mbPerSec)) MB/s")
        return throughput
    }

    // MARK: - Data Generators

    /// Generate 100KB of pure printable ASCII text (random letters + spaces + newlines).
    private func generatePrintableASCII(size: Int = 100_000) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            if i % 80 == 79 {
                data[i] = 0x0A // newline every 80 chars
            } else {
                // Random printable ASCII: 0x20-0x7E
                data[i] = UInt8.random(in: 0x20...0x7E)
            }
        }
        return data
    }

    /// Generate SGR-heavy output simulating `ls --color` (colored filenames).
    private func generateSGRHeavy(size: Int = 100_000) -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(size)
        let colors: [[UInt8]] = [
            Array("\u{1B}[0m".utf8),       // reset
            Array("\u{1B}[1;31m".utf8),     // bold red
            Array("\u{1B}[32m".utf8),       // green
            Array("\u{1B}[1;34m".utf8),     // bold blue
            Array("\u{1B}[33m".utf8),       // yellow
            Array("\u{1B}[36m".utf8),       // cyan
            Array("\u{1B}[1;35m".utf8),     // bold magenta
            Array("\u{1B}[38;5;208m".utf8), // 256-color orange
        ]
        var colorIdx = 0
        while data.count < size {
            // Add SGR sequence
            let sgr = colors[colorIdx % colors.count]
            data.append(contentsOf: sgr)
            colorIdx += 1
            // Add 8-20 chars of "filename"
            let nameLen = Int.random(in: 8...20)
            for _ in 0..<nameLen {
                data.append(UInt8.random(in: 0x61...0x7A)) // a-z
            }
            // Add separator
            data.append(0x20) // space
        }
        // Reset at end
        data.append(contentsOf: Array("\u{1B}[0m".utf8))
        return data
    }

    /// Generate cursor movement heavy output simulating vim screen redraw.
    private func generateCursorMovement(size: Int = 100_000) -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(size)
        while data.count < size {
            // CUP: move to random position
            let row = Int.random(in: 1...50)
            let col = Int.random(in: 1...120)
            data.append(contentsOf: Array("\u{1B}[\(row);\(col)H".utf8))
            // Write a few characters
            let textLen = Int.random(in: 1...10)
            for _ in 0..<textLen {
                data.append(UInt8.random(in: 0x20...0x7E))
            }
            // EL: erase to end of line
            data.append(contentsOf: Array("\u{1B}[K".utf8))
        }
        return data
    }

    /// Generate mixed workload (text + SGR + cursor + scroll).
    private func generateMixedWorkload(size: Int = 100_000) -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(size)
        while data.count < size {
            let choice = Int.random(in: 0...3)
            switch choice {
            case 0: // Plain text line
                let len = Int.random(in: 20...80)
                for _ in 0..<len {
                    data.append(UInt8.random(in: 0x20...0x7E))
                }
                data.append(0x0D) // CR
                data.append(0x0A) // LF
            case 1: // SGR + text
                data.append(contentsOf: Array("\u{1B}[1;32m".utf8))
                let len = Int.random(in: 5...15)
                for _ in 0..<len {
                    data.append(UInt8.random(in: 0x61...0x7A))
                }
                data.append(contentsOf: Array("\u{1B}[0m".utf8))
            case 2: // CUP
                let row = Int.random(in: 1...24)
                let col = Int.random(in: 1...80)
                data.append(contentsOf: Array("\u{1B}[\(row);\(col)H".utf8))
            case 3: // EL
                data.append(contentsOf: Array("\u{1B}[K".utf8))
            default:
                break
            }
        }
        return data
    }

    // MARK: - Benchmarks

    @Test func benchmarkPrintableASCII() {
        let data = generatePrintableASCII()
        let _ = measureThroughput(label: "Printable ASCII", data: data)
    }

    @Test func benchmarkSGRHeavy() {
        let data = generateSGRHeavy()
        let _ = measureThroughput(label: "SGR Heavy", data: data)
    }

    @Test func benchmarkCursorMovement() {
        let data = generateCursorMovement()
        let _ = measureThroughput(label: "Cursor Movement", data: data)
    }

    @Test func benchmarkMixedWorkload() {
        let data = generateMixedWorkload()
        let _ = measureThroughput(label: "Mixed Workload", data: data)
    }
}
