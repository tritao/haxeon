package haxeon.agent;

/** Read-only tools run freely; anything that mutates host state needs approval. */
class SupervisedPolicy implements ToolPolicy {
	public function new() {}

	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return tool.access == ReadOnly ? Allow : Ask;
}
