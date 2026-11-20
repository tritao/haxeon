package compiler.abi;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrTypeIdentity;

/** Deterministic semantic descriptions of every runtime-visible declaration. */
typedef RuntimeAbiDescriptor = {
	final functions:Map<String, String>;
	final objects:Map<String, String>;
	final interfaces:Map<String, String>;
	final enums:Map<String, String>;
	final globals:Map<String, String>;

	/**
	 * Code fingerprint of every positionally named function (`PositionalName`), which tells whether an edit moved those names onto
	 * other functions (see `PatchPlanner.renumberedGroups`); null when the descriptor was persisted before builds recorded them.
	 */
	final positional:Null<Map<String, String>>;

	/**
	 * Where each positionally named function starts (`PositionalName.place`) and the text of the files they are in, so an
	 * edit's text diff can tell edited lambdas apart (`LambdaAlignment`). Kept in memory only: a resumed session matches by
	 * code alone.
	 */
	final ?places:Null<Map<String, String>>;

	final ?sources:Null<Map<String, String>>;
}

/** Canonical description of the runtime-visible ABI emitted to HashLink. */
class RuntimeAbi {
	public static function describe(program:IrProgram):RuntimeAbiDescriptor {
		var functions:Map<String, String> = [],
			objects:Map<String, String> = [],
			interfaces:Map<String, String> = [],
			enums:Map<String, String> = [],
			globals:Map<String, String> = [];
		for (fn in program.functions)
			functions.set(fn.name, functionSignature(fn));
		for (object in program.objects)
			objects.set(object.name,
				'kind=${object.isValue ? "value" : "object"};base=${object.base};interfaces=${object.interfaces.join(",")};fields=${[for (field in object.fields) fieldSignature(field)].join(",")};methods=${[for (method in object.methods) method.name + ":" + method.functionName].join(",")}');
		for (declaration in program.interfaces)
			interfaces.set(declaration.name,
				'bases=${declaration.bases.join(",")};methods=${[for (method in declaration.methods) method.name + signature(method.arguments, method.result)].join(",")}');
		for (declaration in program.enums) {
			var schema = [
				for (constructor in declaration.cases)
					constructor.name + "(" + [for (parameter in constructor.params) typeKey(parameter)].join(",") + ")"
			].join(";");
			var storage = declaration.inlineStorage;
			if (storage != null) schema = "inline=" + storage + ";" + schema;
			enums.set(declaration.name, schema);
		}
		for (field in program.staticFields)
			globals.set(field.name, typeKey(field.type));
		return {
			functions: functions,
			objects: objects,
			interfaces: interfaces,
			enums: enums,
			globals: globals,
			positional: [for (name => fingerprint in program.positionalFingerprints) name => fingerprint],
			places: [for (name => place in program.positionalPlaces) name => place],
			sources: program.positionalSources
		};
	}

	static function fieldSignature(field:IrObjectField):String {
		var scalar = field.scalarStorage, nullable = field.nullableScalarStorage;
		return field.name + ":" + typeKey(field.type)
			+ (scalar == null ? "" : ":storage=" + scalar.size + ":" + scalar.signed)
			+ (nullable == null ? "" : ":nullable-storage=" + nullable.size + ":" + nullable.signed);
	}

	/** A function's signature, as `signature` spells it, without collecting its argument types first. */
	static function functionSignature(fn:IrFunction):String {
		var out = new StringBuf();
		out.add("(");
		for (index in 0...fn.arguments.length) {
			if (index > 0)
				out.add(",");
			writeKey(out, fn.arguments[index].type);
		}
		out.add(")->");
		writeKey(out, fn.result);
		return out.toString();
	}

	static function signature(arguments:Array<IrType>, result:IrType):String {
		var out = new StringBuf();
		writeSignature(out, arguments, result);
		return out.toString();
	}

	static function typeKey(type:IrType):String {
		var out = new StringBuf();
		writeKey(out, type);
		return out.toString();
	}

	static function writeSignature(out:StringBuf, arguments:Array<IrType>, result:IrType):Void {
		out.add("(");
		for (index in 0...arguments.length) {
			if (index > 0)
				out.add(",");
			writeKey(out, arguments[index]);
		}
		out.add(")->");
		writeKey(out, result);
	}

	static function writeKey(out:StringBuf, type:IrType):Void
		switch type {
			case Array(element):
				out.add("Array<");
				writeKey(out, element);
				out.add(">");
			case Function(arguments, result):
				writeSignature(out, arguments, result);
			default:
				IrTypeIdentity.write(out, type);
		}
}
