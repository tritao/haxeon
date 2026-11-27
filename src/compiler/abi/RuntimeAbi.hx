package compiler.abi;

import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIdentity;

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
	/**
	 * `kept` keeps the text of each function, object, interface and enum while it is the same object. `previous`, the description
	 * of the build before, lends the tables that read the same, so the descriptions a live session keeps of its publications share
	 * what an edit did not change instead of each holding its own.
	 */
	public static function describe(program:IrProgram, ?kept:RuntimeAbiTexts,
			?previous:RuntimeAbiDescriptor):RuntimeAbiDescriptor {
		var names:Array<String> = [], texts:Array<String> = [];
		for (fn in program.functions) {
			var signatures = kept == null ? null : kept.functions,
				signature = signatures == null ? null : signatures.of(fn);
			if (signature == null) {
				signature = functionSignature(fn);
				if (signatures != null)
					signature = signatures.keep(fn, signature);
			}
			names.push(fn.name);
			texts.push(signature);
		}
		var functions = table(names, texts, previous == null ? null : previous.functions);
		names = [];
		texts = [];
		for (object in program.objects) {
			names.push(object.name);
			texts.push(kept == null ? objectText(object) : kept.text(object.name, object, objectText));
		}
		var objects = table(names, texts, previous == null ? null : previous.objects);
		names = [];
		texts = [];
		for (declaration in program.interfaces) {
			names.push(declaration.name);
			texts.push(kept == null ? interfaceText(declaration) : kept.text(declaration.name, declaration,
				interfaceText));
		}
		var interfaces = table(names, texts, previous == null ? null : previous.interfaces);
		names = [];
		texts = [];
		for (declaration in program.enums) {
			names.push(declaration.name);
			texts.push(kept == null ? enumText(declaration) : kept.text(declaration.name, declaration, enumText));
		}
		var enums = table(names, texts, previous == null ? null : previous.enums);
		var globals:Map<String, String> = [];
		for (field in program.staticFields)
			globals.set(field.name, typeKey(field.type));
		var positional:Map<String, String> =
			[for (name => fingerprint in program.positionalFingerprints) name => fingerprint],
			places:Map<String, String> = [for (name => place in program.positionalPlaces) name => place];
		return {
			functions: functions,
			objects: objects,
			interfaces: interfaces,
			enums: enums,
			globals: sameOr(globals, previous == null ? null : previous.globals),
			positional: sameOr(positional, previous == null ? null : previous.positional),
			places: sameOr(places, previous == null ? null : previous.places),
			sources: sameOr(program.positionalSources, previous == null ? null : previous.sources)
		};
	}

	static function objectText(object:IrObject):String
		return 'kind=${object.isValue ? "value" : "object"};base=${object.base};interfaces=${object.interfaces.join(",")};fields=${[for (field in object.fields) fieldSignature(field)].join(",")};methods=${[for (method in object.methods) method.name + ":" + method.functionName].join(",")}';

	static function interfaceText(declaration:IrInterface):String
		return 'bases=${declaration.bases.join(",")};methods=${[for (method in declaration.methods) method.name + signature(method.arguments, method.result)].join(",")}';

	static function enumText(declaration:IrEnum):String {
		var schema = [
			for (constructor in declaration.cases)
				constructor.name + "(" + [for (parameter in constructor.params) typeKey(parameter)].join(",") + ")"
		].join(";");
		var storage = declaration.inlineStorage;
		return storage != null ? "inline=" + storage + ";" + schema : schema;
	}

	/**
	 * The table of `names` and their `texts`: `previous` when it has exactly these entries, else a new one, a later entry of a name
	 * taking its place.
	 */
	static function table(names:Array<String>, texts:Array<String>,
			previous:Null<Map<String, String>>):Map<String, String> {
		if (previous != null) {
			var same = true;
			for (index in 0...names.length)
				if (previous.get(names[index]) != texts[index]) {
					same = false;
					break;
				}
			if (same) {
				var count = 0;
				for (_ in previous.keys())
					count++;
				if (count == names.length)
					return previous;
			}
		}
		var made:Map<String, String> = [];
		for (index in 0...names.length)
			made.set(names[index], texts[index]);
		return made;
	}

	/** `previous` when it has exactly the entries of `next`, else `next`. */
	static function sameOr(next:Map<String, String>, previous:Null<Map<String, String>>):Map<String, String> {
		if (previous == null || previous == next)
			return next;
		var count = 0;
		for (name => value in next) {
			if (previous.get(name) != value)
				return next;
			count++;
		}
		for (_ in previous.keys())
			if (--count < 0)
				return next;
		return previous;
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

/**
 * The texts the runtime ABI describes each function and declaration by (`RuntimeAbi.describe`), as kinds of the session's database:
 * a function's while it is the same object (`IrFunctionValues`), a declaration's (an object, an interface, an enum) by the number
 * of its name while it is the same object as the one the text was made of: one kind for the three, as names of different
 * declarations differ, and one that did not would only have its text made again.
 */
class RuntimeAbiTexts {
	final database:compiler.query.QueryDatabase;

	public final functions:compiler.ir.reuse.IrFunctionValues<String>;

	final declarations:compiler.query.ComputedQueryKind<RuntimeAbiText>;

	public function new(database:compiler.query.QueryDatabase) {
		this.database = database;
		functions = new compiler.ir.reuse.IrFunctionValues<String>(database, "abi-functions",
			(left, right) -> left == right);
		declarations = database.register(new compiler.query.ComputedQueryKind<RuntimeAbiText>("abi-declarations",
			RuntimeAbiText.same));
	}

	/** The text of `declaration`, named `name`: the one kept when it was made of that object, else `make`'s, kept. */
	public function text<T>(name:String, declaration:T, make:T->String):String {
		var key = compiler.ir.model.IrSymbol.of(name).id, known = declarations.kept(key);
		if (known != null && known.declaration == declaration) {
			declarations.hold(database, declarations.slotOf(key));
			return known.text;
		}
		return declarations.put(database, key, new RuntimeAbiText(declaration, make(declaration))).text;
	}
}

/** A declaration's text in the runtime ABI, with the declaration it was made of. */
class RuntimeAbiText {
	public final declaration:Dynamic;
	public final text:String;

	public function new(declaration:Dynamic, text:String) {
		this.declaration = declaration;
		this.text = text;
	}

	public static function same(left:RuntimeAbiText, right:RuntimeAbiText):Bool
		return left.declaration == right.declaration && left.text == right.text;
}
