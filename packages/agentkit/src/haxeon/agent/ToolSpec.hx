package haxeon.agent;

class ToolSpec {
	public final name:String;
	public final description:String;
	public final schemaJson:String;

	public function new(name:String, description:String, schemaJson:String) {
		this.name = name;
		this.description = description;
		this.schemaJson = schemaJson;
	}
}
