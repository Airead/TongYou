import Foundation
import Testing
@testable import TYCLIUtils

@Suite("extractProfileAndSet")
struct ArgUtilsTests {

    // MARK: - Happy path

    @Test("no flags returns defaults with all args in remaining")
    func noFlags() throws {
        let result = try extractProfileAndSet(["s1", "--vertical", "--focus"])
        #expect(result.profile == nil)
        #expect(result.overrides == [])
        #expect(result.remaining == ["s1", "--vertical", "--focus"])
    }

    @Test("--profile captures the following value")
    func profileFlag() throws {
        let result = try extractProfileAndSet(["--profile", "prod-ssh", "s1"])
        #expect(result.profile == "prod-ssh")
        #expect(result.overrides == [])
        #expect(result.remaining == ["s1"])
    }

    @Test("repeated --profile: last value wins")
    func profileRepeated() throws {
        let result = try extractProfileAndSet(
            ["--profile", "ci", "--profile", "prod"]
        )
        #expect(result.profile == "prod")
    }

    @Test("single --set becomes one 'key = value' line")
    func singleSet() throws {
        let result = try extractProfileAndSet(["--set", "font-size=20"])
        #expect(result.overrides == ["font-size = 20"])
    }

    @Test("multiple --set preserve order")
    func multipleSet() throws {
        let result = try extractProfileAndSet([
            "--set", "font-size=20",
            "--set", "theme=dark",
            "--set", "palette-0=ffffff",
        ])
        #expect(result.overrides == [
            "font-size = 20",
            "theme = dark",
            "palette-0 = ffffff",
        ])
    }

    @Test("--set env=KEY=VALUE keeps everything after the first '='")
    func setMultiEquals() throws {
        let result = try extractProfileAndSet([
            "--set", "env=HTTP_PROXY=http://proxy:8080/path?x=y",
        ])
        #expect(result.overrides == [
            "env = HTTP_PROXY=http://proxy:8080/path?x=y",
        ])
    }

    @Test("--set with empty RHS preserved for explicit-clear")
    func setEmptyRhs() throws {
        let result = try extractProfileAndSet(["--set", "env="])
        #expect(result.overrides == ["env = "])
    }

    @Test("--profile and --set interleaved with other args")
    func interleavedArgs() throws {
        let result = try extractProfileAndSet([
            "s1",
            "--profile", "ci",
            "--horizontal",
            "--set", "args=--flag1",
            "--focus",
            "--set", "args=--flag2",
        ])
        #expect(result.profile == "ci")
        #expect(result.overrides == ["args = --flag1", "args = --flag2"])
        #expect(result.remaining == ["s1", "--horizontal", "--focus"])
    }

    // MARK: - Error paths

    @Test("--profile without value throws profileFlagMissingValue")
    func profileMissingValue() {
        #expect(throws: ArgParseError.profileFlagMissingValue) {
            _ = try extractProfileAndSet(["--profile"])
        }
    }

    @Test("--set without value throws setFlagMissingValue")
    func setMissingValue() {
        #expect(throws: ArgParseError.setFlagMissingValue) {
            _ = try extractProfileAndSet(["--set"])
        }
    }

    @Test("--set with no '=' in value throws setFlagMissingEquals")
    func setMissingEquals() {
        #expect(throws: ArgParseError.setFlagMissingEquals("invalidnoequals")) {
            _ = try extractProfileAndSet(["--set", "invalidnoequals"])
        }
    }

    // MARK: - Edge cases

    @Test("empty argv returns empty result")
    func emptyArgs() throws {
        let result = try extractProfileAndSet([])
        #expect(result.profile == nil)
        #expect(result.overrides == [])
        #expect(result.remaining == [])
    }

    @Test("positional args that look like values are untouched")
    func positionalPassthrough() throws {
        // `--set-something` is NOT `--set`; it should land in remaining verbatim.
        let result = try extractProfileAndSet(["--set-something", "foo=bar"])
        #expect(result.profile == nil)
        #expect(result.overrides == [])
        #expect(result.remaining == ["--set-something", "foo=bar"])
    }
}
