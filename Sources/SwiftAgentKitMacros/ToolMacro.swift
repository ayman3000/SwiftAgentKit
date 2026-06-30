import Foundation
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Entry point for the SwiftAgentKit macro plugin.
@main
struct SwiftAgentKitMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ToolMacro.self,
    ]
}

/// `@Tool("description")` — attached to a function, generates an `AgentTool`-conforming
/// struct that wraps the function. The function becomes callable by LLM models.
///
/// Usage:
/// ```swift
/// @Tool("Return the current date and time.")
/// func currentTime() async throws -> String {
///     Date().formatted(date: .complete, time: .standard)
/// }
/// ```
///
/// With parameters:
/// ```swift
/// @Tool("Calculate a basic arithmetic expression.")
/// func calculator(expression: String) async throws -> String {
///     "646"
/// }
/// ```
public struct ToolMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Ensure we're attached to a function
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw ToolMacroError.notAFunction
        }

        // Extract the description from the macro argument
        let description: String
        if let argument = node.arguments?.as(LabeledExprListSyntax.self)?.first {
            if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self) {
                description = stringLiteral.segments.compactMap { segment in
                    segment.as(StringSegmentSyntax.self)?.content.text
                }.joined()
            } else {
                throw ToolMacroError.invalidDescription
            }
        } else {
            description = ""
        }

        let funcName = funcDecl.name.text
        let toolName = camelToSnake(funcName)
        let structName = funcName.prefix(1).uppercased() + funcName.dropFirst() + "Tool"

        // Build parameter properties from the function signature
        let params = funcDecl.signature.parameterClause.parameters
        var properties: [String] = []
        var requiredParams: [String] = []
        var paramExtractions: [String] = []

        for param in params {
            let paramName = param.firstName.text
            let paramType = param.type.trimmedDescription

            let schemaType = swiftTypeToSchema(paramType)
            // Extract DocC comment if present
            let paramDesc = extractDocCComment(for: paramName, from: funcDecl) ?? "\(paramName)"

            properties.append("""
            "\(paramName)": ToolParameterProperty(type: "\(schemaType)", description: "\(paramDesc)")
            """)

            requiredParams.append("\"\(paramName)\"")

            // Generate extraction code based on type
            if schemaType == "string" {
                paramExtractions.append("let \(paramName) = context.parameters[\"\(paramName)\"] as? String ?? \"\"")
            } else if schemaType == "integer" {
                paramExtractions.append("let \(paramName) = context.parameters[\"\(paramName)\"] as? Int ?? 0")
            } else if schemaType == "number" {
                paramExtractions.append("let \(paramName) = context.parameters[\"\(paramName)\"] as? Double ?? 0.0")
            } else if schemaType == "boolean" {
                paramExtractions.append("let \(paramName) = context.parameters[\"\(paramName)\"] as? Bool ?? false")
            } else {
                paramExtractions.append("let \(paramName) = context.parameters[\"\(paramName)\"] as? String ?? \"\"")
            }
        }

        // Build the parameters expression
        let parametersExpr: String
        if properties.isEmpty {
            parametersExpr = "ToolParameters.empty"
        } else {
            parametersExpr = """
            ToolParameters(
                properties: [
                    \(properties.joined(separator: ",\n                    "))
                ],
                required: [\(requiredParams.joined(separator: ", "))]
            )
            """
        }

        // Build the call to the handler closure (no labels — closures don't have them)
        let handlerCallArgs = params.map { p in p.firstName.text }.joined(separator: ", ")

        // Build the call to the original function (with labels — Swift requires them)
        let funcCallArgs = params.map { p in "\(p.firstName.text): \(p.firstName.text)" }.joined(separator: ", ")

        // Build type signature for the handler closure
        // e.g. "String" for a single param, or "" for no params
        let paramTypeSignature: String
        if params.isEmpty {
            paramTypeSignature = ""
        } else {
            paramTypeSignature = params.map { p in p.type.trimmedDescription }.joined(separator: ", ")
        }

        // Build closure parameter signature
        // e.g. "(expression: String)" or "" for no params
        let paramClosureSignature: String
        if params.isEmpty {
            paramClosureSignature = ""
        } else {
            paramClosureSignature = "(" + params.map { p in "\(p.firstName.text): \(p.type.trimmedDescription)" }.joined(separator: ", ") + ")"
        }

        // Generate the struct and a factory method
        // The factory method name is: funcName + "Tool"
        let factoryName = funcName + "Tool"

        // The struct stores a closure that calls the original function.
        // The factory method captures `self` and the function reference.
        let structCode = """
        struct \(structName): AgentTool {
            let name = "\(toolName)"
            let description = "\(description)"
            let parameters = \(parametersExpr)
            private let handler: @Sendable (\(paramTypeSignature)) async throws -> String

            init(handler: @escaping @Sendable (\(paramTypeSignature)) async throws -> String) {
                self.handler = handler
            }

            func execute(parameters: [String: Any]) async throws -> AgentToolResult {
                let context = ToolContext(
                    callId: "",
                    toolName: "\(toolName)",
                    parameters: parameters,
                    state: AgentState(),
                    turn: 0,
                    query: ""
                )
                return try await execute(context: context)
            }

            func execute(context: ToolContext) async throws -> AgentToolResult {
                \(paramExtractions.joined(separator: "\n                "))
                let result = try await handler(\(handlerCallArgs))
                return .success(toolCallId: context.callId, toolName: name, result: result)
            }
        }

        func \(factoryName)() -> \(structName) {
            \(structName)(handler: { [self] \(paramClosureSignature) in
                try await \(funcName)(\(funcCallArgs))
            })
        }
        """

        return [DeclSyntax(stringLiteral: structCode)]
    }

    // MARK: - Helpers

    /// Convert CamelCase to snake_case
    private static func camelToSnake(_ s: String) -> String {
        var result = ""
        for (i, char) in s.enumerated() {
            if char.isUppercase && i > 0 {
                result.append("_")
            }
            result.append(char.lowercased())
        }
        return result
    }

    /// Map Swift types to JSON Schema types
    private static func swiftTypeToSchema(_ swiftType: String) -> String {
        switch swiftType {
        case "String": return "string"
        case "Int", "Int32", "Int64": return "integer"
        case "Double", "Float": return "number"
        case "Bool": return "boolean"
        case "[String]": return "array"
        default: return "string"
        }
    }

    /// Extract DocC comment for a parameter from the function declaration
    private static func extractDocCComment(for paramName: String, from funcDecl: FunctionDeclSyntax) -> String? {
        let trivia = funcDecl.leadingTrivia
        for piece in trivia {
            switch piece {
            case .docLineComment(let raw):
                let text = String(raw)
                // Strip the "///" prefix
                let content = text.replacingOccurrences(of: "///", with: "").trimmingCharacters(in: CharacterSet.whitespaces)
                if content.hasPrefix("- Parameter \(paramName):") {
                    let desc = content.dropFirst("- Parameter \(paramName):".count)
                    return desc.trimmingCharacters(in: CharacterSet.whitespaces)
                }
                if content.hasPrefix("\(paramName):") {
                    let desc = content.dropFirst("\(paramName):".count)
                    return desc.trimmingCharacters(in: CharacterSet.whitespaces)
                }
            case .docBlockComment(let raw):
                let text = String(raw)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    if trimmed.hasPrefix("- Parameter \(paramName):") {
                        let desc = trimmed.dropFirst("- Parameter \(paramName):".count)
                        return desc.trimmingCharacters(in: CharacterSet.whitespaces)
                    }
                    if trimmed.hasPrefix("\(paramName):") {
                        let desc = trimmed.dropFirst("\(paramName):".count)
                        return desc.trimmingCharacters(in: CharacterSet.whitespaces)
                    }
                }
            default:
                break
            }
        }
        return nil
    }
}

enum ToolMacroError: Error, CustomStringConvertible {
    case notAFunction
    case invalidDescription

    var description: String {
        switch self {
        case .notAFunction:
            return "@Tool can only be attached to functions"
        case .invalidDescription:
            return "@Tool requires a string literal description"
        }
    }
}