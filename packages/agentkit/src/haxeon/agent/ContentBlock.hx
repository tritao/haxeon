package haxeon.agent;

/** Tool input stays raw JSON text so conversations serialize without untyped values. */
enum ContentBlock {
	/** Text from the user or the model. */
	Text(text:String);

	/** The model's call of tool `name`, with its input as JSON. */
	ToolUse(id:String, name:String, inputJson:String);

	/** A tool's result for call `id`. */
	ToolOutput(id:String, content:String, isError:Bool);
}
