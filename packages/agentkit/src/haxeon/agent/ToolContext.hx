package haxeon.agent;

/** Per-call context handed to a tool. */
class ToolContext {
	public final callId:String;

	public function new(callId:String)
		this.callId = callId;
}
