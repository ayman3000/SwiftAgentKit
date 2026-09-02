/// A finality-tagged item in `Agent.runStreamingTagged`. `delta` is incremental
/// text of the in-progress turn (live). `turnCompleted` fires once per finished
/// turn — `wasToolCallTurn` distinguishes a step (narrated, then called tools)
/// from the final answer (last turn, no tool calls).
public enum AgentStreamEvent: Sendable, Equatable {
    case delta(String)
    /// Live delta of the model's separated reasoning for the in-progress turn.
    /// Never part of the answer; UIs may show it as "thinking" progress. Not
    /// echoed in `.turnCompleted` — it is transient by design.
    case reasoningDelta(String)
    case turnCompleted(text: String, wasToolCallTurn: Bool)
}
