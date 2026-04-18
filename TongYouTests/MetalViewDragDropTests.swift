import Foundation
import Testing
@testable import TongYou

/// Unit tests for the path-quoting helper used when files are dropped from
/// Finder onto a pane. Focused on the pure string logic; exercising the full
/// `NSDraggingInfo` flow requires UI machinery and is not covered here.
@MainActor
struct MetalViewDragDropTests {

    @Test func quotesPlainPath() {
        #expect(MetalView.shellQuote("/tmp/file.txt") == "'/tmp/file.txt'")
    }

    @Test func quotesPathWithSpaces() {
        #expect(
            MetalView.shellQuote("/Users/me/My Documents/report.pdf")
                == "'/Users/me/My Documents/report.pdf'"
        )
    }

    @Test func escapesEmbeddedSingleQuote() {
        // POSIX: close, emit literal ', reopen — '\''
        #expect(
            MetalView.shellQuote("/tmp/it's fine.txt")
                == "'/tmp/it'\\''s fine.txt'"
        )
    }

    @Test func escapesMultipleSingleQuotes() {
        #expect(
            MetalView.shellQuote("a'b'c")
                == "'a'\\''b'\\''c'"
        )
    }

    @Test func quotesShellMetacharacters() {
        // $, `, \, ", ;, & and the like are inert inside single quotes — the
        // output only needs to be wrapped, not further escaped.
        #expect(
            MetalView.shellQuote("/tmp/$(evil) `x`; rm -rf \\ \"q\"")
                == "'/tmp/$(evil) `x`; rm -rf \\ \"q\"'"
        )
    }

    @Test func quotesEmptyString() {
        #expect(MetalView.shellQuote("") == "''")
    }

    @Test func quotesUnicodePath() {
        #expect(
            MetalView.shellQuote("/tmp/项目 报告.md")
                == "'/tmp/项目 报告.md'"
        )
    }

    @Test func joinsMultiplePathsWithSpace() {
        let quoted = ["/a/b", "/c d/e"].map(MetalView.shellQuote).joined(separator: " ")
        #expect(quoted == "'/a/b' '/c d/e'")
    }
}
