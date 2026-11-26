package haxeon.agent;

/** A model's request to run one tool. */
class ToolCall {
	/** The call's id, which its result answers. */
	public final id:String;

	/** The tool called. */
	public final name:String;

	/** Its input, as JSON text. */
	public final inputJson:String;

	/** A call of tool `name`. */
	public function new(id:String, name:String, inputJson:String) {
		this.id = id;
		this.name = name;
		this.inputJson = inputJson;
	}
}
