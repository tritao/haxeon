package haxeon.agent;

/**
	A capability the host exposes to the model. `execute` completes through
	`done` exactly once, possibly later, so tools can wait on host work such as
	file reads, searches or a frame boundary without blocking the UI thread.
**/
class AgentTool {
	/** The name the model calls it by. */
	public final name:String;

	/** What it does, for the model. */
	public final description:String;

	/** Its input's parameters. */
	public final schema:ToolSchema;

	/** Whether it changes host state. */
	public final access:ToolAccess;

	/** A tool; subclasses override `execute`. */
	public function new(name:String, description:String, schema:ToolSchema, access:ToolAccess) {
		this.name = name;
		this.description = description;
		this.schema = schema;
		this.access = access;
	}

	/** One line shown when the policy asks the user to approve this call. */
	public function summarize(input:JsonObject):String
		return name;

	/**
	 * Runs the call with `input` and passes its result to `done`, now or later. The default reports the tool as not
	 * implemented.
	 */
	public function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		done(ToolResult.error("Tool is not implemented: " + name));
}
