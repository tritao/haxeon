package haxeon.agent;

/** How an agent runs: which model it talks to, the tools it may use and the limits of a run. */
class AgentOptions {
	/** Where model turns come from. */
	public final provider:ModelProvider;

	/** The model's name, as the provider knows it. */
	public final model:String;

	/** The system prompt. */
	public final system:String;

	/** The tools the model may call. */
	public final tools:Array<AgentTool>;

	/** Decides whether each tool call may run. */
	public final policy:ToolPolicy;

	/** The most tokens one model turn may produce. */
	public final maxTokens:Int;

	/** The most model turns one run may take before it fails. */
	public final maxTurns:Int;

	/** Options for an agent; the limits default to 8192 tokens a turn and 40 turns a run. */
	public function new(provider:ModelProvider, model:String, system:String, tools:Array<AgentTool>, policy:ToolPolicy,
			maxTokens:Int = 8192,
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
