package compiler.backend.wasm;

import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

enum EnumStringFieldKind {
	EnumReference;
	EnumInteger;
	EnumBoolean;
	EnumInteger64;
	EnumFloat;
	EnumTagField;
}

typedef EnumStringFieldDescriptor = {
	final kind:EnumStringFieldKind;
	final tagNames:Array<String>;
}

typedef EnumStringCaseDescriptor = {
	final name:String;
	final parameters:Array<IrType>;

	/** Index into descriptors, or -1 for a constructor without payload. */
	final descriptor:Int;
}

typedef EnumStringGroupDescriptor = {
	final name:String;
	final cases:Array<EnumStringCaseDescriptor>;
}

/** Target-independent names, field kinds and shared payload shapes for enum stringification. */
class EnumStringDescriptors {
	public static inline final REFERENCE = 0;
	public static inline final INTEGER = 1;
	public static inline final BOOLEAN = 2;
	public static inline final INTEGER64 = 3;
	public static inline final FLOAT = 4;
	public static inline final TAG = 5;

	public final groups:Array<EnumStringGroupDescriptor> = [];
	public final descriptors:Array<Array<EnumStringFieldDescriptor>> = [];
	public var hasPayload(default, null):Bool = false;

	public function new(program:IrProgram, selected:Map<String, Bool>, declarations:Array<IrEnum>) {
		if (!selected.keys().hasNext())
			return;
		var logical:Map<String, Int> = [],
			enums:Null<Map<String, IrEnum>> = null;
		for (entry in program.enums)
			if (selected.exists(entry.name)) {
				var cases:Array<EnumStringCaseDescriptor> = [];
				for (constructor in entry.cases) {
					var fields:Array<EnumStringFieldDescriptor> = [];
					for (type in constructor.params) {
						var tags:Array<String> = [];
						var kind = switch type {
							case I32: EnumInteger;
							case Bool: EnumBoolean;
							case I64: EnumInteger64;
							case F32 | F64: EnumFloat;
							case EnumTag(name):
								if (enums == null) {
									enums = [];
									for (declaration in declarations)
										enums.set(declaration.name, declaration);
								}
								var declaration = enums.get(name);
								if (declaration == null)
									throw 'Missing enum declaration "$name"';
								for (item in declaration.cases)
									tags.push(item.name);
								EnumTagField;
							default: EnumReference;
						};
						fields.push({kind: kind, tagNames: tags});
					}
					var descriptor = -1;
					if (fields.length > 0) {
						hasPayload = true;
						var key = fieldKey(fields),
							existing = logical.get(key);
						if (existing == null) {
							descriptor = descriptors.length;
							descriptors.push(fields);
							logical.set(key, descriptor);
						} else
							descriptor = existing;
					}
					cases.push({
						name: constructor.params.length == 0 ? constructor.name : constructor.name + "(",
						parameters: constructor.params,
						descriptor: descriptor
					});
				}
				groups.push({name: entry.name, cases: cases});
			}
	}

	public static function code(kind:EnumStringFieldKind):Int
		return switch kind {
			case EnumReference: REFERENCE;
			case EnumInteger: INTEGER;
			case EnumBoolean: BOOLEAN;
			case EnumInteger64: INTEGER64;
			case EnumFloat: FLOAT;
			case EnumTagField: TAG;
		};

	/** The key is used only for interning; lengths make arbitrary tag names unambiguous. */
	static function fieldKey(fields:Array<EnumStringFieldDescriptor>):String {
		var result = new StringBuf();
		for (field in fields) {
			result.add(code(field.kind));
			result.add(":");
			result.add(field.tagNames.length);
			result.add(":");
			for (name in field.tagNames) {
				result.add(name.length);
				result.add(":");
				result.add(name);
			}
			result.add(";");
		}
		return result.toString();
	}

	/** Constructor strings precede tag strings to keep static-string placement deterministic. */
	public function names():Array<String> {
		var result:Array<String> = [];
		for (group in groups)
			for (item in group.cases)
				result.push(item.name);
		for (group in groups)
			for (item in group.cases)
				if (item.descriptor >= 0)
					for (field in descriptors[item.descriptor])
						for (name in field.tagNames)
							result.push(name);
		return result;
	}
}
