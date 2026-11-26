package haxeon.agent;

/** Everything a UI needs to render a run. Events are delivered in order on the host's thread. */
enum AgentEvent {
	/** A run began. */
	RunStarted;

	/** The model was asked for turn `turn`, counting from one. */
	TurnStarted(turn:Int);

	/** The model streamed more text. */
	TextDelta(text:String);

	/** A message joined the conversation. */
	MessageCompleted(message:Message);

	/** A tool call began running. */
	ToolStarted(call:ToolCall);

	/** A tool call waits for `resolveApproval`; `summary` says what it would do. */
	ApprovalRequested(call:ToolCall, summary:String);

	/** A tool call finished with `result`. */
	ToolCompleted(call:ToolCall, result:ToolResult);

	/** The run ended, for `reason`. */
	RunEnded(reason:StopReason);
}
