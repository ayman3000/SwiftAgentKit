/// `@Tool` converts a Swift function into an `AgentTool`-conforming struct.
///
/// The macro generates:
/// - A struct conforming to `AgentTool`
/// - Tool name (snake_case from the function name)
/// - Description (from the macro argument)
/// - JSON-Schema parameters (from the function signature)
/// - Tool result wrapping (`.success(toolCallId:toolName:result:)`)
///
/// Usage — define tools inside a `ToolContainer`:
/// ```swift
/// struct MyTools: ToolContainer {
///     @Tool("Return the current date and time.")
///     func currentTime() async throws -> String {
///         Date().formatted(date: .complete, time: .standard)
///     }
/// }
/// let agent = Agent(config: ...)
/// agent.register(MyTools().currentTimeTool())
/// ```
///
/// With parameters:
/// ```swift
/// @Tool("Calculate a basic arithmetic expression.")
/// func calculator(expression: String) async throws -> String {
///     "646"
/// }
/// agent.register(MyTools().calculatorTool())
/// ```
///
/// Alpha limitations:
/// - Parameters generated from the function signature are currently advertised as required;
///   optional/default arguments are not represented in the emitted schema yet.
/// - The supported path is primitive parameters: `String`, `Int`, `Double`, and `Bool`.
/// - Arrays, nested objects, and enums should use a manual `AgentTool` definition for now.
/// - Malformed model arguments can coerce to primitive defaults (`""`, `0`, `0.0`, `false`);
///   validate inside the tool for critical operations.
/// - DocC parameter extraction handles simple `- Parameter name:` comments; grouped
///   `- Parameters:` blocks are not fully parsed yet.
@attached(peer, names: arbitrary)
public macro Tool(_ description: String) = #externalMacro(module: "SwiftAgentKitMacros", type: "ToolMacro")

// MARK: - Convenience for registering macro-generated tools

/// A type-erased wrapper for macro-generated tools, providing a factory function.
public struct MacroTool {
    /// Create an instance of a macro-generated tool.
    public static func make<T: AgentTool>(_ tool: T) -> T { tool }
}