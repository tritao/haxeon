package haxeon.agent;

enum PolicyDecision {
	Allow;
	Deny(reason:String);
	/** Pause the run and emit ApprovalRequested until the host calls `resolveApproval`. */
	Ask;
}
