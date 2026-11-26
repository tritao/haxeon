package haxeon.agent;

/** Per-call context handed to a tool. */
class ToolContext {
	/** The id of the call being run. */
	public final callId:String;

	/** The context of call `callId`. */
	public function new(callId:String)
		this.callId = callId;
}
