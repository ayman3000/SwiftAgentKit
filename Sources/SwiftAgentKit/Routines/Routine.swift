import Foundation

/// A proven automation: named inputs, fixed steps, no model between them.
///
/// The point is not that the steps are written down — a skill does that, and the
/// model still pays a turn per step reading it. The point is that a routine
/// EXECUTES without asking a model anything, so a task that cost a dozen model
/// turns costs one: the turn that fills in the inputs.
///
/// Deliberately not a language. Inputs are values substituted into steps, never
/// expressions; steps run in order with no branching and no loops. A step that
/// fails stops the routine and hands control back, which is the only "control
/// flow" there is.
public struct Routine: Codable, Sendable, Equatable, Identifiable {

    /// A blank the caller fills: the file to read, the name to save under.
    public struct Input: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var required: Bool
        public var defaultValue: String?

        public init(name: String, description: String, required: Bool = true, defaultValue: String? = nil) {
            self.name = name; self.description = description
            self.required = required; self.defaultValue = defaultValue
        }
    }

    /// One tool call. Strings in `arguments` may contain `{input}` placeholders.
    public struct Step: Codable, Sendable, Equatable {
        /// Compared by their encoded form: arguments hold arbitrary JSON, and
        /// AnyCodable's own == cannot handle a bare string at the top level.
        public static func == (a: Step, b: Step) -> Bool {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(a)) == (try? encoder.encode(b))
        }

        public var tool: String
        public var arguments: [String: AnyCodable]
        /// Shown in the run report instead of raw arguments when present.
        public var note: String?

        public init(tool: String, arguments: [String: AnyCodable], note: String? = nil) {
            self.tool = tool; self.arguments = arguments; self.note = note
        }
    }

    public var name: String
    public var description: String
    public var inputs: [Input]
    public var steps: [Step]
    /// When this routine last completed end to end. A routine is only worth
    /// trusting because it ran; one that never has is a plan, not a routine.
    public var lastSucceededAt: Date?
    public var createdAt: Date

    public var id: String { name }

    public init(name: String, description: String, inputs: [Input] = [], steps: [Step],
                lastSucceededAt: Date? = nil, createdAt: Date = Date()) {
        self.name = name; self.description = description
        self.inputs = inputs; self.steps = steps
        self.lastSucceededAt = lastSucceededAt; self.createdAt = createdAt
    }

    // MARK: - Substitution

    /// `{name}` in any string becomes the supplied value. Unknown placeholders
    /// are left alone rather than blanked: a step that would act on an empty
    /// path is more dangerous than one that visibly fails.
    public static func substitute(_ value: AnyCodable, with values: [String: String]) -> AnyCodable {
        if let s = value.value as? String { return AnyCodable(fill(s, values)) }
        if let arr = value.value as? [Any] {
            return AnyCodable(arr.map { substitute(AnyCodable($0), with: values).value })
        }
        if let dict = value.value as? [String: Any] {
            return AnyCodable(dict.mapValues { substitute(AnyCodable($0), with: values).value })
        }
        return value
    }

    static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
        return out
    }

    /// Placeholders used anywhere in the steps — so a routine can be checked
    /// against its declared inputs instead of failing halfway through.
    public var placeholdersUsed: Set<String> {
        var found: Set<String> = []
        func scan(_ value: Any) {
            if let s = value as? String {
                var rest = Substring(s)
                while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                    let key = String(rest[rest.index(after: open)..<close])
                    if !key.isEmpty, !key.contains(" ") { found.insert(key) }
                    rest = rest[rest.index(after: close)...]
                }
            } else if let arr = value as? [Any] { arr.forEach(scan) }
            else if let dict = value as? [String: Any] { dict.values.forEach(scan) }
        }
        for step in steps { step.arguments.values.forEach { scan($0.value) } }
        return found
    }

    /// Names the steps use that no input declares.
    public var undeclaredPlaceholders: [String] {
        placeholdersUsed.subtracting(inputs.map(\.name)).sorted()
    }
}

// MARK: - Storage

public protocol RoutineStore: Sendable {
    func all() async throws -> [Routine]
    func save(_ routine: Routine) async throws
    func delete(name: String) async throws
}

/// One JSON file per routine, so they can be read, edited and diffed by hand.
public struct FileRoutineStore: RoutineStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(Self.fileSafe(name) + ".json")
    }

    /// A routine name is used as a filename; keep it to something harmless.
    public static func fileSafe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public func all() async throws -> [Routine] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Routine.self, from: $0) }
        }.sorted { $0.name < $1.name }
    }

    public func save(_ routine: Routine) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(routine).write(to: url(for: routine.name), options: .atomic)
    }

    public func delete(name: String) async throws {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
