package haxeon.agent;

/** One canned model turn for a ScriptedProvider. */
class ScriptedResponse {
	/** The text the turn streams. */
	public final text:String;

	/** The tool calls it makes. */
	public final calls:Array<ToolCall>;

	/** Why it ends. */
	public final reason:StopReason;

	/** A failure to report instead, or null. */
	public final failure:Null<String>;

	/** A turn streaming `text`, making `calls` and ending for `reason`, or failing with `failure`. */
	public function new(text:String, calls:Array<ToolCall>, reason:StopReason, ?failure:String) {
		this.text = text;
		this.calls = calls;
		this.reason = reason;
		this.failure = failure;
	}

	/** A turn that says `text` and ends. */
	public static function say(text:String):ScriptedResponse
		return new ScriptedResponse(text, [], EndTurn);

	/** A turn that says `text` and calls `calls`. */
	public static function useTools(text:String, calls:Array<ToolCall>):ScriptedResponse
		return new ScriptedResponse(text, calls, ToolCalls);

	/** A turn that fails with `message`. */
	public static function failWith(message:String):ScriptedResponse
		return new ScriptedResponse("", [], EndTurn, message);
}
