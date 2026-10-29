package haxeon.agent;

class FullAccessPolicy implements ToolPolicy {
	public function new() {}

	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return Allow;
}
