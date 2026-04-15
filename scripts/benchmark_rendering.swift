#!/usr/bin/env swift

import Foundation

// 模拟 opencode 风格的逐字流式输出，用来压测渲染循环。
// 特点：不换行、逐字累积，让终端每收到几个字符就重绘一次。

let duration = 5.0           // 测试持续时间（秒）
let charsPerBurst = 3        // 每次突发输出多少字符
let burstIntervalUs = 500    // 每次突发间隔（微秒）

let sentences = [
    "The quick brown fox jumps over the lazy dog.",
    "Now is the time for all good men to come to the aid of the party.",
    "SwiftUI and Metal combine to deliver smooth terminal rendering.",
    "Ghostty uses a draw timer with an 8 ms interval to coalesce frames.",
    "Profiling with Instruments reveals where the CPU spends its cycles.",
]

let colors: [String] = [
    "\u{001B}[31m", "\u{001B}[32m", "\u{001B}[33m", "\u{001B}[34m",
    "\u{001B}[35m", "\u{001B}[36m", "\u{001B}[0m",
]

func write(_ string: String) {
    guard !string.isEmpty else { return }
    FileHandle.standardOutput.write(Data(string.utf8))
}

let start = Date()
var totalChars = 0
var lineIndex = 0

while Date().timeIntervalSince(start) < duration {
    let color = colors[lineIndex % colors.count]
    let sentence = sentences[lineIndex % sentences.count]
    let text = "\(color)[\(lineIndex)] \(sentence)\u{001B}[0m"
    
    // 逐字突发输出
    var offset = text.startIndex
    while offset < text.endIndex {
        let end = text.index(offset, offsetBy: charsPerBurst, limitedBy: text.endIndex) ?? text.endIndex
        let chunk = String(text[offset..<end])
        write(chunk)
        fflush(stdout)
        totalChars += chunk.count
        
        usleep(useconds_t(burstIntervalUs))
        offset = end
    }
    
    // 行尾换行
    write("\n")
    fflush(stdout)
    lineIndex += 1
}

print("\nDone. Total lines: \(lineIndex), total chars: \(totalChars)")
