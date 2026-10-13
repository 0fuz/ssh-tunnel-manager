import Foundation

// Run from the repository root:
// swiftc SSHTunnelManager/SSHTunnelManager/Services/SSHConfigAliasScanner.swift \
//   SSHTunnelManager/Tests/SSHConfigAliasScannerTests.swift -o /tmp/ssh-alias-tests
// /tmp/ssh-alias-tests
@main
struct SSHConfigAliasScannerTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        try check("quoted absolute include", files: [
            ".ssh/config": "Include \"{HOME}/managed servers/config\"\nHost local",
            "managed servers/config": "Host included included-backup\n  HostName example.invalid"
        ], expected: ["included", "included-backup", "local"])

        try check("nested relative includes use the SSH directory", files: [
            ".ssh/config": "Include conf.d/first.conf",
            ".ssh/conf.d/first.conf": "Host first\nInclude second.conf",
            ".ssh/second.conf": "Host second",
            ".ssh/conf.d/second.conf": "Host wrong-directory"
        ], expected: ["first", "second"])

        try check("glob and multiple include arguments", files: [
            ".ssh/config": "Include conf.d/[ab]?.conf extra.conf missing/*.conf",
            ".ssh/conf.d/a1.conf": "Host Alpha",
            ".ssh/conf.d/b2.conf": "Host beta",
            ".ssh/conf.d/c3.conf": "Host excluded",
            ".ssh/extra.conf": "Host gamma"
        ], expected: ["Alpha", "beta", "gamma"])

        try check("tilde includes", files: [
            ".ssh/config": "Include ~/configs/hosts",
            "configs/hosts": "Host tilde-host"
        ], expected: ["tilde-host"])

        try check("case, equals, quotes and comments", files: [
            ".ssh/config": """
            # Include ignored.conf
              iNcLuDe = "conf with spaces.conf" 'single quotes.conf' # ignored.conf
            hOsT=Zulu "alpha" !excluded *.invalid question? Zulu # phantom
            Host = bravo
            """,
            ".ssh/conf with spaces.conf": "Host charlie",
            ".ssh/single quotes.conf": "Host delta",
            ".ssh/ignored.conf": "Host ignored"
        ], expected: ["alpha", "bravo", "charlie", "delta", "Zulu"])

        try check("hash characters within paths and aliases", files: [
            ".ssh/config": "Include conf#hosts.conf # ignored.conf\nHost local#name # phantom",
            ".ssh/conf#hosts.conf": "Host remote#name",
            ".ssh/ignored.conf": "Host ignored"
        ], expected: ["local#name", "remote#name"])

        try check("escaped glob wildcards stay literal", files: [
            ".ssh/config": "Include literal\\*.conf",
            ".ssh/literal*.conf": "Host literal",
            ".ssh/literal-other.conf": "Host wrongly-matched"
        ], expected: ["literal"])

        try check("include cycles and duplicate aliases", files: [
            ".ssh/config": "Host local\nInclude config cycle.conf cycle.conf",
            ".ssh/cycle.conf": "Host local remote\nInclude config"
        ], expected: ["local", "remote"])

        try check("symlink include cycles", files: [
            ".ssh/config": "Host local\nInclude loop.conf"
        ], links: [".ssh/loop.conf": "config"], expected: ["local"])

        try check("missing files preserve other aliases", files: [
            ".ssh/config": "Include absent.conf\nHost available\nInclude valid.conf",
            ".ssh/valid.conf": "Host included"
        ], expected: ["available", "included"])

        try check("missing main config", files: [:], expected: [])

        try check("refresh rescans changed include files", files: [
            ".ssh/config": "Include included.conf",
            ".ssh/included.conf": "Host before"
        ], expected: ["before"]) { home in
            try "Host after".write(
                to: home.appendingPathComponent(".ssh/included.conf"),
                atomically: true, encoding: .utf8
            )
            try expect(SSHConfigAliasScanner.aliases(homeDirectory: home), ["after"])
        }

        var deepFiles = [".ssh/config": "Include depth0.conf\nHost root"]
        for index in 0..<30 {
            deepFiles[".ssh/depth\(index).conf"] = "Include depth\(index + 1).conf\nHost deep"
        }
        try check("excessive include nesting terminates", files: deepFiles,
                  expected: ["deep", "root"])

        print("All 13 SSH config alias scanner checks passed.")
    }

    private static func check(
        _ name: String, files: [String: String], links: [String: String] = [:],
        expected: [String], after: ((URL) throws -> Void)? = nil
    ) throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        for (path, contents) in files {
            let url = home.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try contents.replacingOccurrences(of: "{HOME}", with: home.path)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        for (path, destination) in links {
            try manager.createSymbolicLink(atPath: home.appendingPathComponent(path).path,
                                           withDestinationPath: destination)
        }
        do {
            try expect(SSHConfigAliasScanner.aliases(homeDirectory: home), expected)
            try after?(home)
        } catch {
            throw Failure(description: "\(name): \(error)")
        }
        print("PASS: \(name)")
    }

    private static func expect(_ actual: [String], _ expected: [String]) throws {
        guard actual == expected else {
            throw Failure(description: "expected \(expected), got \(actual)")
        }
    }
}
