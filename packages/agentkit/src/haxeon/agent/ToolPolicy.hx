package haxeon.agent;

/** The host decides what the model may do; agentkit never executes a tool without asking its policy. */
interface ToolPolicy {
	function decide(tool:AgentTool, input:JsonObject):PolicyDecision;
}
