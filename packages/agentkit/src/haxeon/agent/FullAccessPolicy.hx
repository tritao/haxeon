package haxeon.agent;

/** Lets every tool call run without asking. */
class FullAccessPolicy implements ToolPolicy {
	/** The policy. */
	public function new() {}

	/** Always `Allow`. */
	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return Allow;
}
