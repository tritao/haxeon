package haxeon.ui.properties;

/** Presentation metadata for a named field. Absent fields are added explicitly;
 * defaults and placeholder values are copied before staging. */
class PropertyRecordField {
	public final name:String;
	public final structure:PropertyStructure;
	public final optional:Bool;
	final initialJson:String;
	public function new(name:String, structure:PropertyStructure, optional:Bool = false, initial:Dynamic = null) {
		this.name = name; this.structure = structure; this.optional = optional;
		initialJson = haxe.Json.stringify(initial);
	}
	public function initialValue():Dynamic return haxe.Json.parse(initialJson);
}
