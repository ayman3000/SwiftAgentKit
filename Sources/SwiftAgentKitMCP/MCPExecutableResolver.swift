import Foundation

enum MCPExecutableResolver {
    static func enrichedEnvironment(
        _ environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result = environment
        let fallbackDirectories = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existingDirectories = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen = Set<String>()
        result["PATH"] = (fallbackDirectories + existingDirectories)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return result
    }

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
