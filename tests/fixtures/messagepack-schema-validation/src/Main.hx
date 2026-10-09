import haxe.Json;
import haxeon.wire.MessagePackSchema;
import sys.io.File;

struct SchemaLeaf {
	public var zero:Int = 0;
	public var optional:Null<Int> = null;
	public var narrow:UInt8 = 250;
	public var absent:Int;
}
struct SchemaRoot {
	public var leaf:SchemaLeaf;
	public var title:String = "root";
}
function rejects(action:Void->Void):Bool {
	try {
		action();
	} catch (_:Dynamic) {
		return true;
	}
	return false;
}

function field(fields:Array<Dynamic>, name:String):Dynamic {
	for (value in fields)
		if (Reflect.field(value, "name") == name)
			return value;
	throw 'missing schema fixture field "$name"';
}

function main():Int {
	var artifactPath = Sys.getEnv("HAXEON_SCHEMA_VALIDATION_ARTIFACT");
	if (artifactPath == null)
		throw "HAXEON_SCHEMA_VALIDATION_ARTIFACT must name the generated descriptor artifact";
	var json = File.getContent(artifactPath),
		info:Dynamic = typeInfo<SchemaRoot>(),
		schema = MessagePackSchema.fromJson(json);
	schema.requireDescriptor(info.hash, info.type);
	var zero = schema.fieldDefaultValue(info.hash, info.type, ["leaf", "zero"]),
		optional = schema.fieldDefaultValue(info.hash, info.type, ["leaf", "optional"]),
		narrow = schema.fieldDefaultValue(info.hash, info.type, ["leaf", "narrow"]),
		absent = schema.fieldDefaultValue(info.hash, info.type, ["leaf", "absent"]),
		title = schema.fieldDefaultValue(info.hash, info.type, ["title"]);
	if (zero == null || zero.type != "Int" || zero.value != 0 || optional == null || optional.type != "Null" || optional.value != null || narrow == null
		|| narrow.type != "Int" || narrow.value != 250 || absent != null || title == null || title.type != "String" || title.value != "root")
		return 1;
	if (!rejects(function() MessagePackSchema.fromJson('{"formatVersion":2,"descriptors":[]}')))
		return 2;
	if (!rejects(function() schema.fieldDefaultValue(info.hash, info.type, ["leaf", "missing"])))
		return 3;
	if (!rejects(function() MessagePackSchema.fromJson(StringTools.replace(json, info.hash, StringTools.lpad("", "0", 64)))))
		return 4;
	var wrongType:Dynamic = Json.parse(json),
		descriptors:Array<Dynamic> = cast Reflect.field(wrongType, "descriptors"),
		root:Dynamic = null;
	for (descriptor in descriptors)
		if (Reflect.field(descriptor, "hash") == info.hash)
			root = descriptor;
	var leaf = field(cast Reflect.field(root, "fields"), "leaf"),
		leafFields:Array<Dynamic> = cast Reflect.field(leaf, "fields");
	Reflect.setField(field(leafFields, "zero"), "defaultValue", {type: "String", value: "wrong"});
	if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(wrongType))))
		return 5;
	var outOfRange:Dynamic = Json.parse(json),
		outDescriptors:Array<Dynamic> = cast Reflect.field(outOfRange, "descriptors");
	for (descriptor in outDescriptors)
		if (Reflect.field(descriptor, "hash") == info.hash) {
			var outLeaf = field(cast Reflect.field(descriptor, "fields"), "leaf"),
				outLeafFields:Array<Dynamic> = cast Reflect.field(outLeaf, "fields");
			Reflect.setField(field(outLeafFields, "narrow"), "defaultValue", {type: "Int", value: 256});
		}
	if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(outOfRange))))
		return 6;
	return 42;
}
