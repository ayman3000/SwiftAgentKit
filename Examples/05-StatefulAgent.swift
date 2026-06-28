//
//  05-StatefulAgent.swift
//  SwiftAgentKit Examples
//
//  Pattern: ReAct + Agent State
//  Shows: Tools sharing data via AgentState, {key} instruction templating,
//         ToolContext for reading/writing state
//
//  Scenario: A customer support agent that:
//  1. Looks up the user's account (stores info in state)
//  2. Checks their order history (reads from state)
//  3. Files a support ticket (uses state for user info)
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Stateful Tools
// ──────────────────────────────────────────────

struct LookupAccountTool: AgentTool {
    let name = "lookup_account"
    let description = "Look up a customer account by email address."
    let parameters = ToolParameters(
        properties: [
            "email": ToolParameterProperty(type: "string", description: "Customer email address")
        ],
        required: ["email"]
    )

    // Uses execute(context:) to write to agent state
    func execute(context: ToolContext) async throws -> AgentToolResult {
        let email = context.parameters["email"] as? String ?? ""

        // Simulate a database lookup
        let mockCustomers: [String: [String: String]] = [
            "alex@example.com": ["name": "Alex", "tier": "pro", "id": "CUST-001"],
            "sara@example.com": ["name": "Sara", "tier": "free", "id": "CUST-002"],
        ]

        guard let customer = mockCustomers[email] else {
            return .error(toolCallId: context.callId, toolName: name, message: "No account found for \(email)")
        }

        // Store customer info in state — other tools can read this
        context.state.setValue(customer["name"]!, forKey: "user:name")
        context.state.setValue(customer["tier"]!, forKey: "user:tier")
        context.state.setValue(customer["id"]!, forKey: "user:id")

        return .success(
            toolCallId: context.callId, toolName: name,
            result: "Found account: \(customer["name"]!) (ID: \(customer["id"]!), Tier: \(customer["tier"]!))"
        )
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "Use context version")
    }
}

struct CheckOrdersTool: AgentTool {
    let name = "check_orders"
    let description = "Check order history for the current customer."
    let parameters = ToolParameters.empty  // no parameters — reads from state

    func execute(context: ToolContext) async throws -> AgentToolResult {
        // Read the customer ID from state (set by LookupAccountTool)
        guard let customerId = context.state.string(forKey: "user:id") else {
            return .error(toolCallId: context.callId, toolName: name,
                         message: "No customer loaded. Call lookup_account first.")
        }

        // Simulate order lookup based on customer ID
        let orders = customerId == "CUST-001"
            ? ["Order #1001: Swift book ($29) - delivered", "Order #1002: USB-C cable ($12) - shipped"]
            : ["Order #2001: Notebook ($5) - delivered"]

        // Store the order count in state for later use
        context.state.setValue(orders.count, forKey: "user:order_count")

        return .success(
            toolCallId: context.callId, toolName: name,
            result: "Orders for \(customerId):\n" + orders.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        )
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "Use context version")
    }
}

struct FileTicketTool: AgentTool {
    let name = "file_ticket"
    let description = "File a support ticket for the current customer."
    let parameters = ToolParameters(
        properties: [
            "subject": ToolParameterProperty(type: "string", description: "Ticket subject"),
            "description": ToolParameterProperty(type: "string", description: "Ticket description")
        ],
        required: ["subject", "description"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        // Read customer info from state (set by LookupAccountTool)
        let customerName = context.state.string(forKey: "user:name") ?? "Unknown"
        let customerId = context.state.string(forKey: "user:id") ?? "N/A"
        let orderCount = context.state.int(forKey: "user:order_count") ?? 0

        let subject = context.parameters["subject"] as? String ?? ""
        let description = context.parameters["description"] as? String ?? ""

        let ticketId = "TKT-\(Int.random(in: 1000...9999))"

        return .success(
            toolCallId: context.callId, toolName: name,
            result: """
            Ticket filed successfully!
            Ticket ID: \(ticketId)
            Customer: \(customerName) (\(customerId))
            Orders on file: \(orderCount)
            Subject: \(subject)
            Description: \(description)
            """
        )
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "Use context version")
    }
}

// ──────────────────────────────────────────────
// Run the agent
// ──────────────────────────────────────────────

func statefulAgentExample() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        // The system prompt uses {key} templating — values are substituted from state
        systemPrompt: """
        You are a customer support agent.
        Current customer: {user:name} (Tier: {user:tier})
        Always look up the customer first, check their orders, then help them.
        """,
        maxTurns: 10,
        enableRepairRetry: true
    ))

    // Pre-set the email in state so the agent knows who to look up
    agent.state.setValue("alex@example.com", forKey: "user:email")

    agent.register(LookupAccountTool())
    agent.register(CheckOrdersTool())
    agent.register(FileTicketTool())

    agent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call):
            print("🔧 \(call.name)")
        case .toolExecutionFinished(_, let result):
            print("  → \(result.result.prefix(120))")
        case .finished(let summary):
            print("\n✨ Done in \(summary.totalTurns) turns, \(summary.toolsExecuted) tools called")
        default: break
        }
    }

    // The agent will:
    // Turn 1: call lookup_account("alex@example.com") → stores name/tier/id in state
    // Turn 2: call check_orders() → reads user:id from state, returns order history
    // Turn 3: call file_ticket() → reads user:name, user:id, user:order_count from state
    // Turn 4: no more tool calls → returns a summary
    //
    // Notice: the system prompt "{user:name}" and "{user:tier}" are substituted
    // from state BEFORE each LLM call, so the model always knows who it's helping.
    let result = try await agent.run("I haven't received my USB-C cable yet. File a ticket for me.")
    print("\n📋 Result:\n\(result)")
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await statefulAgentExample()
}