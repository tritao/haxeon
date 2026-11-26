package haxeon.agent;

/** What a tool call returns to the model. */
class ToolResult {
	/** The result's text. */
	public final content:String;

	/** Whether the call failed. */
	public final isError:Bool;

	/** A result holding `content`. */
	public function new(content:String, isError:Bool = false) {
		this.content = content;
		this.isError = isError;
	}

	/** A successful result. */
	public static function ok(content:String):ToolResult
		return new ToolResult(content, false);

	/** A failed result, explaining why in `content`. */
	public static function error(content:String):ToolResult
		return new ToolResult(content, true);
}
