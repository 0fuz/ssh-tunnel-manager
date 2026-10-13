import Foundation
import Darwin

/// Lists explicit Host names in the user's SSH config and its Include files.
/// OpenSSH still evaluates Match conditions and resolves connection options.
enum SSHConfigAliasScanner {
    static func aliases(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        var visited = Set<URL>()
        var result = Set<String>()

        func scan(_ configURL: URL, depth: Int) {
            let canonicalURL = configURL.standardizedFileURL.resolvingSymlinksInPath()
            // Bound nested includes as well as stopping cycles through symlinks.
            guard depth <= 16, visited.insert(canonicalURL).inserted,
                  let contents = try? String(contentsOf: canonicalURL, encoding: .utf8) else {
                return
            }

            for line in contents.components(separatedBy: .newlines) {
                guard let (keyword, arguments) = directive(in: line) else { continue }

                switch keyword.lowercased() {
                case "host":
                    for alias in arguments {
                        guard !alias.contains("*"), !alias.contains("?"),
                              !alias.hasPrefix("!") else { continue }
                        result.insert(alias)
                    }
                case "include":
                    for pattern in arguments {
                        for url in includedFiles(
                            matching: pattern, sshDirectory: sshDirectory,
                            homeDirectory: homeDirectory
                        ) {
                            scan(url, depth: depth + 1)
                        }
                    }
                default:
                    continue
                }
            }
        }

        scan(sshDirectory.appendingPathComponent("config"), depth: 0)
        return result.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func includedFiles(
        matching pattern: String, sshDirectory: URL, homeDirectory: URL
    ) -> [URL] {
        var path = pattern
        if path == "~" {
            path = homeDirectory.path
        } else if path.hasPrefix("~/") {
            path = homeDirectory.path + String(path.dropFirst())
        } else if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        // User-config Include paths are relative to ~/.ssh, even in nested files.
        if !path.hasPrefix("/") {
            path = sshDirectory.path + "/" + path
        }

        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0, let paths = matches.gl_pathv else {
            return []
        }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    /// SSH keywords may use whitespace or '='; paths may be quoted and contain spaces.
    private static func directive(in line: String) -> (String, [String])? {
        let trimmed = line.drop(while: { $0.isWhitespace })
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let keyword = trimmed.prefix(while: { !$0.isWhitespace && $0 != "=" })
        var remainder = trimmed.dropFirst(keyword.count).drop(while: { $0.isWhitespace })
        if remainder.first == "=" {
            remainder = remainder.dropFirst().drop(while: { $0.isWhitespace })
        }

        var arguments: [String] = []
        var argument = ""
        var quote: Character?
        let characters = Array(remainder)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\", index < characters.count {
                let next = characters[index]
                if next == "\\" || next == "\"" || next == "'"
                    || (quote == nil && next.isWhitespace) {
                    argument.append(next)
                    index += 1
                    continue
                }
                // Preserve other backslashes so glob can honor escaped wildcards.
            }
            if let delimiter = quote {
                if character == delimiter {
                    quote = nil
                } else {
                    argument.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" && argument.isEmpty {
                break
            } else if character.isWhitespace {
                if !argument.isEmpty {
                    arguments.append(argument)
                    argument = ""
                }
            } else {
                argument.append(character)
            }
        }
        guard quote == nil else { return nil }
        if !argument.isEmpty { arguments.append(argument) }
        return (String(keyword), arguments)
    }
}
