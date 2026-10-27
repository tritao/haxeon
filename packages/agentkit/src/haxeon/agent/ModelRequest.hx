package haxeon.agent;

class ModelRequest {
	public final model:String;
	public final system:String;
	public final messages:Array<Message>;
	public final tools:Array<ToolSpec>;
	public final maxTokens:Int;

	public function new(model:String, system:String, messages:Array<Message>, tools:Array<ToolSpec>, maxTokens:Int) {
		this.model = model;
		this.system = system;
		this.messages = messages;
		this.tools = tools;
		this.maxTokens = maxTokens;
	}
}
