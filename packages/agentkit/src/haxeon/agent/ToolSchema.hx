package haxeon.agent;

private typedef Property = {
	var name:String;
	var type:String;
	var description:String;
	var required:Bool;
	var choices:Array<String>;
}

/** JSON Schema for a tool's arguments: a flat object whose properties are strings, integers or booleans. */
class ToolSchema {
	final properties:Array<Property> = [];

	public function new() {}

	public function string(name:String, description:String, required:Bool = true, ?choices:Array<String>):ToolSchema
		return add(name, "string", description, required, choices);

	public function integer(name:String, description:String, required:Bool = false):ToolSchema
		return add(name, "integer", description, required, null);

	public function boolean(name:String, description:String, required:Bool = false):ToolSchema
		return add(name, "boolean", description, required, null);

	function add(name:String, type:String, description:String, required:Bool, choices:Null<Array<String>>):ToolSchema {
		properties.push({
			name: name,
			type: type,
			description: description,
			required: required,
			choices: choices == null ? [] : choices
		});
		return this;
	}

	public function toJson():String {
		var fields:Array<String> = [];
		var required:Array<String> = [];
		for (property in properties) {
			var parts = [
				JsonWriter.stringField("type", property.type),
				JsonWriter.stringField("description", property.description)
			];
			if (property.choices.length > 0)
				parts.push(JsonWriter.field("enum", JsonWriter.array([for (choice in property.choices) JsonWriter.quote(choice)])));
			fields.push(JsonWriter.field(property.name, JsonWriter.object(parts)));
			if (property.required)
				required.push(JsonWriter.quote(property.name));
		}
		return JsonWriter.object([
			JsonWriter.stringField("type", "object"),
			JsonWriter.field("properties", JsonWriter.object(fields)),
			JsonWriter.field("required", JsonWriter.array(required))
		]);
	}
}
