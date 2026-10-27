package haxeon.agent;

class ScriptedResponse {
	public final text:String;
	public final calls:Array<ToolCall>;
	public final reason:StopReason;
	public final failure:Null<String>;

	public function new(text:String, calls:Array<ToolCall>, reason:StopReason, ?failure:String) {
		this.text = text;
		this.calls = calls;
		this.reason = reason;
		this.failure = failure;
	}

	public static function say(text:String):ScriptedResponse
		return new ScriptedResponse(text, [], EndTurn);

	public static function useTools(text:String, calls:Array<ToolCall>):ScriptedResponse
		return new ScriptedResponse(text, calls, ToolCalls);

	public static function failWith(message:String):ScriptedResponse
		return new ScriptedResponse("", [], EndTurn, message);
}
