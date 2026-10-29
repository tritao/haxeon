package haxeon.agent;

/** Tool input stays raw JSON text so conversations serialize without untyped values. */
enum ContentBlock {
	Text(text:String);
	ToolUse(id:String, name:String, inputJson:String);
	ToolOutput(id:String, content:String, isError:Bool);
}
