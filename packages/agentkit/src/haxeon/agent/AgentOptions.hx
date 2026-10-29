package haxeon.agent;

class AgentOptions {
	public final provider:ModelProvider;
	public final model:String;
	public final system:String;
	public final tools:Array<AgentTool>;
	public final policy:ToolPolicy;
	public final maxTokens:Int;
	public final maxTurns:Int;

	public function new(provider:ModelProvider, model:String, system:String, tools:Array<AgentTool>, policy:ToolPolicy, maxTokens:Int = 8192,
			maxTurns:Int = 40) {
		this.provider = provider;
		this.model = model;
		this.system = system;
		this.tools = tools;
		this.policy = policy;
		this.maxTokens = maxTokens;
		this.maxTurns = maxTurns;
	}
}
