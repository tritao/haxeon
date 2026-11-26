package haxeon.agent;

/** Whether a tool call may run. */
enum PolicyDecision {
	/** Run it. */
	Allow;

	/** Refuse it, telling the model `reason`. */
	Deny(reason:String);
	/** Pause the run and emit ApprovalRequested until the host calls `resolveApproval`. */
	Ask;
}
