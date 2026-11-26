package haxeon.agent;

/** What an agent is doing. */
enum AgentState {
	/** No run is active; `send` starts one. */
	Idle;

	/** The model is producing a turn. */
	Streaming;

	/** A tool call is running. */
	RunningTool;

	/** A tool call waits for `resolveApproval`. */
	AwaitingApproval;
}
