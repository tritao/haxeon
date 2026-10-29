package haxeon.agent;

/** A model's request to run one tool. */
class ToolCall {
	public final id:String;
	public final name:String;
	public final inputJson:String;

	public function new(id:String, name:String, inputJson:String) {
		this.id = id;
		this.name = name;
		this.inputJson = inputJson;
	}
}
