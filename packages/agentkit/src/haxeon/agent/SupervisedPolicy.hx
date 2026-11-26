package haxeon.agent;

/** Read-only tools run freely; anything that mutates host state needs approval. */
class SupervisedPolicy implements ToolPolicy {
	/** The policy. */
	public function new() {}

	/** `Allow` for read-only tools, `Ask` for the rest. */
	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return tool.access == ReadOnly ? Allow : Ask;
}
