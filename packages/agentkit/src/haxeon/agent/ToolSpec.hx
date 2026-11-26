package haxeon.agent;

/** A tool as a model request describes it. */
class ToolSpec {
	/** The tool's name. */
	public final name:String;

	/** What it does. */
	public final description:String;

	/** Its input's JSON Schema. */
	public final schemaJson:String;

	/** A description of tool `name`. */
	public function new(name:String, description:String, schemaJson:String) {
		this.name = name;
		this.description = description;
		this.schemaJson = schemaJson;
	}
}
