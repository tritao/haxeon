package haxeon.agent;

class ToolResult {
	public final content:String;
	public final isError:Bool;

	public function new(content:String, isError:Bool = false) {
		this.content = content;
		this.isError = isError;
	}

	public static function ok(content:String):ToolResult
		return new ToolResult(content, false);

	public static function error(content:String):ToolResult
		return new ToolResult(content, true);
}
