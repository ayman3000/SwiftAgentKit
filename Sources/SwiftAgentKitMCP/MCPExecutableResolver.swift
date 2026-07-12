import Foundation

enum MCPExecutableResolver {
    static func resolve(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let fileManager = FileManager.default
        let expanded = NSString(string: command).expandingTildeInPath

        if expanded.contains("/") {
            guard fileManager.isExecutableFile(atPath: expanded) else {
                throw MCPManagerError.executableNotFound(command)
            }
            return URL(fileURLWithPath: expanded)
        }

        var directories = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        directories.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw MCPManagerError.executableNotFound(command)
    }
}
