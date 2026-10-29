package haxeon.agent;

/**
	A capability the host exposes to the model. `execute` completes through
	`done` exactly once, possibly later, so tools can wait on host work such as
	file reads, searches or a frame boundary without blocking the UI thread.
**/
class AgentTool {
	public final name:String;
	public final description:String;
	public final schema:ToolSchema;
	public final access:ToolAccess;

	public function new(name:String, description:String, schema:ToolSchema, access:ToolAccess) {
		this.name = name;
		this.description = description;
		this.schema = schema;
		this.access = access;
	}

	/** One line shown when the policy asks the user to approve this call. */
	public function summarize(input:JsonObject):String
		return name;

	public function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		done(ToolResult.error("Tool is not implemented: " + name));
}
