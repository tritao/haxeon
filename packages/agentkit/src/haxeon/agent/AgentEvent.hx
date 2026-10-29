package haxeon.agent;

/** Everything a UI needs to render a run. Events are delivered in order on the host's thread. */
enum AgentEvent {
	RunStarted;
	TurnStarted(turn:Int);
	TextDelta(text:String);
	MessageCompleted(message:Message);
	ToolStarted(call:ToolCall);
	ApprovalRequested(call:ToolCall, summary:String);
	ToolCompleted(call:ToolCall, result:ToolResult);
	RunEnded(reason:StopReason);
}
