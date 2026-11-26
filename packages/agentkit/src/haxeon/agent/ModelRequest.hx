package haxeon.agent;

/** What a model turn is asked with. */
class ModelRequest {
	/** The model's name. */
	public final model:String;

	/** The system prompt. */
	public final system:String;

	/** The conversation so far. */
	public final messages:Array<Message>;

	/** The tools the model may call. */
	public final tools:Array<ToolSpec>;

	/** The most tokens the turn may produce. */
	public final maxTokens:Int;

	/** A request for one turn. */
	public function new(model:String, system:String, messages:Array<Message>, tools:Array<ToolSpec>, maxTokens:Int) {
		this.model = model;
		this.system = system;
		this.messages = messages;
		this.tools = tools;
		this.maxTokens = maxTokens;
	}
}
