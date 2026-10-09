import compiler.Compiler;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;
import compiler.types.NativeTypeDescriptorCodec;

class NativeDescriptorConformanceMain {
	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function descriptor(values:Array<NativeTypeDescriptorData>, name:String):NativeTypeDescriptorData {
		for (value in values)
			if (value.name == name)
				return value;
		throw 'Missing native type descriptor "$name"';
	}

	static function contains(values:Array<String>, value:String):Bool
		return values.indexOf(value) >= 0;

	static function main():Void {
		var compiler = new Compiler();
		compiler.configure("descriptor-conformance", "descriptor-conformance", ["native-abi-target=portable-abi64"]);
		compiler.update("schema/Resource.hx", "package schema; interface Resource {}");
		compiler.update("schema/Component.hx", "package schema; interface Component {}");
		compiler.update("schema/BaseResource.hx", "package schema; import schema.Resource; interface BaseResource extends Resource {}");
		compiler.update("schema/GenericMarker.hx", "package schema; interface GenericMarker<T> {}");
		compiler.update("model/FlatResource.hx",
			"package model; import schema.Resource; struct FlatResource : Resource { public var count:Int; public function new() count = 1; }");
		compiler.update("model/InheritedResource.hx",
			"package model; import schema.BaseResource; import schema.GenericMarker; struct InheritedResource : BaseResource, GenericMarker<Int> { " +
			"public var count:Int; public function new() count = 2; }");
		compiler.update("model/ConflictingRoles.hx",
			"package model; import schema.Resource; import schema.Component; struct ConflictingRoles : Resource, Component { " +
			"public var count:Int; public function new() count = 3; }");
		compiler.update("model/NativeValue.hx", "package model; @:value @:repr(\"C\") class NativeValue { public var count:Int; }");
		compiler.update("app/Main.hx",
			"package app; import model.FlatResource; import model.InheritedResource; import model.ConflictingRoles; "
			+ "import model.NativeValue; import schema.Resource; class Main { "
			+ "static function accept<T:Resource>(value:T):String return typeInfo<T>().hash; "
			+ "static function main():Int { var a = accept(new FlatResource()), b = accept(new InheritedResource()), "
			+ "c = accept(new ConflictingRoles()), native = typeInfo<NativeValue>(); "
			+ "return a.length == 64 && b.length == 64 && c.length == 64 && native.hash.length == 64 ? 42 : 1; } }");
		compiler.compile("app.Main");
		var descriptors = compiler.lastTypedProgram.nativeTypeDescriptors,
			flat = descriptor(descriptors, "model.FlatResource"),
			inherited = descriptor(descriptors, "model.InheritedResource"),
			conflicting = descriptor(descriptors, "model.ConflictingRoles"),
			nativeValue = descriptor(descriptors, "model.NativeValue");
		expect(flat.version == 5
			&& flat.sourceKind == "struct"
			&& flat.interfaces.length == 1
			&& flat.interfaces[0] == "interface:schema.Resource<>",
			"direct Resource conformance and source struct kind are emitted");
		expect(inherited.sourceKind == "struct"
			&& inherited.interfaces.join(",") == "interface:schema.BaseResource<>,interface:schema.GenericMarker<Int>,interface:schema.Resource<>",
			"descriptor interfaces include sorted inherited and instantiated generic interface facts");
		expect(conflicting.interfaces.join(",") == "interface:schema.Component<>,interface:schema.Resource<>",
			"compiler reports both declared roles without applying World registration policy");
		expect(nativeValue.sourceKind == "native-value"
			&& nativeValue.type == "native-value:model.NativeValue<>"
			&& nativeValue.version == 5,
			"legacy C value descriptor identity matches the typeInfo<T>() semantic identity");

		var bytes = NativeTypeDescriptorCodec.encode(descriptors),
			decoded = NativeTypeDescriptorCodec.decode(bytes),
			decodedInherited = descriptor(decoded, "model.InheritedResource");
		expect(bytes.get(3) == NativeTypeDescriptorCodec.FORMAT_VERSION
			&& decodedInherited.sourceKind == inherited.sourceKind
			&& decodedInherited.interfaces.join(",") == inherited.interfaces.join(",")
			&& NativeTypeDescriptorCodec.toJson(decoded) == NativeTypeDescriptorCodec.toJson(descriptors),
			"versioned binary and JSON descriptor round-trip preserves conformance facts");
		var incremental = new Compiler();
		incremental.configure("descriptor-interface-invalidation", "descriptor-interface-invalidation", ["native-abi-target=portable-abi64"]);
		incremental.update("schema/Resource.hx", "package schema; interface Resource {}");
		incremental.update("model/Item.hx", "package model; import schema.Resource; struct Item { public var count:Int; }");
		incremental.update("app/Main.hx", "package app; import model.Item; class Main { static function main():Int return typeInfo<Item>().hash.length; }");
		incremental.compile("app.Main");
		var oldDirect = descriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "model.Item");
		incremental.update("model/Item.hx", "package model; import schema.Resource; struct Item : Resource { public var count:Int; }");
		var directCompile = incremental.compile("app.Main"),
			newDirect = descriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "model.Item");
		expect(oldDirect.hash != newDirect.hash && directCompile.retyped.indexOf("app.Main.main") >= 0,
			"adding direct interface conformance changes the descriptor and invalidates cross-module typeInfo callers");
		incremental.update("model/Item.hx", "package model; import schema.Resource; struct Item { public var count:Int; }");
		var removedCompile = incremental.compile("app.Main"),
			removedDirect = descriptor(incremental.lastTypedProgram.nativeTypeDescriptors, "model.Item");
		expect(newDirect.hash != removedDirect.hash && removedCompile.retyped.indexOf("app.Main.main") >= 0,
			"removing direct interface conformance changes the descriptor and invalidates cross-module typeInfo callers");

		var ancestor = new Compiler();
		ancestor.configure("descriptor-interface-ancestor-invalidation", "descriptor-interface-ancestor-invalidation", ["native-abi-target=portable-abi64"]);
		ancestor.update("schema/Resource.hx", "package schema; interface Resource {}");
		ancestor.update("schema/BaseResource.hx", "package schema; import schema.Resource; interface BaseResource extends Resource {}");
		ancestor.update("model/Item.hx", "package model; import schema.BaseResource; struct Item : BaseResource { public var count:Int; }");
		ancestor.update("app/Main.hx", "package app; import model.Item; class Main { static function main():Int return typeInfo<Item>().hash.length; }");
		ancestor.compile("app.Main");
		var oldInherited = descriptor(ancestor.lastTypedProgram.nativeTypeDescriptors, "model.Item");
		ancestor.update("schema/BaseResource.hx", "package schema; interface BaseResource {}");
		var ancestorCompile = ancestor.compile("app.Main"),
			newInherited = descriptor(ancestor.lastTypedProgram.nativeTypeDescriptors, "model.Item");
		expect(contains(oldInherited.interfaces, "interface:schema.Resource<>")
			&& !contains(newInherited.interfaces, "interface:schema.Resource<>")
			&& oldInherited.hash != newInherited.hash
			&& ancestorCompile.retyped.indexOf("app.Main.main") >= 0,
			"changing an ancestor interface invalidates cross-module conformance descriptors and typeInfo callers");
	}
}
