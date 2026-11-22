package compiler.backend.c;

import compiler.hl.HlCode;
import haxe.crypto.Sha256;

/**
 * The C names of a module's types, globals and natives, derived from what each one is rather than from its table position
 * (docs/design/AOT_BACKEND.md, "The C shape"): a type by its path (a function type by a digest of its signature), a global by
 * its name, a native by its library and name. A source change that adds or removes a type, a global or a native then leaves the
 * names of the others as they were, so only the C files that use what changed are written and compiled again.
 */
class HlcStableNames {
	/** The longest name part kept as it is; a longer one is cut and given a digest of the whole. */
	static inline final MAX_LENGTH = 64;

	static inline final CUT_LENGTH = 52;
	static inline final DIGEST_LENGTH = 10;

	final code:HlCode;
	final references:Array<Null<String>> = [];
	final visiting:Map<Int, Bool> = [];

	/** Each type's name part (`hlc_obj_` + it is its struct, `hlc_t_` + it its descriptor), by type index. */
	public final types:Array<String>;

	/** Each global's name part, by global index. */
	public final globals:Array<String>;

	/** Each native's name part, by native slot. */
	public final natives:Map<Int, String> = [];

	/** `globalNames` gives the globals the symbol table knows by name. */
	public function new(code:HlCode, globalNames:Map<String, Int>) {
		this.code = code;
		var bases = [for (index in 0...code.types.length) typeBase(index)],
			contents = [for (index in 0...code.types.length) typeContent(index)];
		types = unique(bases, contents);
		var named:Array<Null<String>> = [for (_ in code.globals) null];
		for (name => index in globalNames)
			if (index < named.length)
				named[index] = name;
		globals = unique([for (index in 0...code.globals.length) named[index] == null ? "global" : part(named[index])],
			[
				for (index in 0...code.globals.length)
					(named[index] == null ? "#" + index : named[index]) + ":" + reference(code.globals[index])
			]);
		var slots = [for (entry in code.natives) entry.functionIndex];
		var nativeNames = unique([
			for (entry in code.natives)
				part(code.strings[entry.library] + "_" + code.strings[entry.name])
		], [
			for (entry in code.natives)
				code.strings[entry.library] + ":" + code.strings[entry.name] + ":" + reference(entry.type)
		]);
		for (index in 0...slots.length)
			natives.set(slots[index], nativeNames[index]);
	}

	/**
	 * Distinct names for items named `bases`: a base more than one item has gets a digest of each item's `contents`, and items
	 * whose contents are the same too are numbered in their order.
	 */
	public static function unique(bases:Array<String>, contents:Array<String>):Array<String> {
		var counts:Map<String, Int> = [];
		for (base in bases)
			counts.set(base, (counts.exists(base) ? counts.get(base) : 0) + 1);
		var names = [
			for (index in 0...bases.length)
				counts.get(bases[index]) > 1 ? bases[index] + "_" + digest(contents[index]) : bases[index]
		];
		var groups:Map<String, Array<Int>> = [];
		for (index in 0...names.length) {
			var group = groups.get(names[index]);
			if (group == null)
				groups.set(names[index], group = []);
			group.push(index);
		}
		var taken = [for (name in names) name => true];
		var keys = [for (name => group in groups) if (group.length > 1) name];
		keys.sort(Reflect.compare);
		for (name in keys) {
			var group = groups.get(name);
			if (group == null)
				continue;
			group.sort((a, b) -> {
				var order = Reflect.compare(contents[a], contents[b]);
				order != 0 ? order : a - b;
			});
			var number = 1;
			for (position in 1...group.length) {
				var candidate;
				do candidate = name + "_" + (++number) while (taken.exists(candidate));
				taken.set(candidate, true);
				names[group[position]] = candidate;
			}
		}
		return names;
	}

	/** A C identifier part for `name`: its characters that are not an identifier's become `_`, and a long one is cut. */
	public static function part(name:String):String {
		var identifier = HlcModule.identifier(name);
		return identifier.length <= MAX_LENGTH ? identifier : identifier.substr(0, CUT_LENGTH) + "_" + digest(name);
	}

	public static function digest(text:String):String
		return Sha256.encode(text).substr(0, DIGEST_LENGTH);

	function text(index:Int):String {
		var value = index >= 0 && index < code.strings.length ? code.strings[index] : null;
		return value == null ? "" : value;
	}

	function typeBase(index:Int):String
		return switch code.types[index] {
			case Simple(kind): Std.string(kind).toLowerCase();
			case EnumTag(boxed, _): part("tag_" + typeBase(boxed));
			case Parameterized(kind, parameter): part(Std.string(kind).toLowerCase() + "_" + typeBase(parameter));
			case Abstract(name): part("abstract_" + text(name));
			case Function(_, _): "fun_" + digest(reference(index));
			case Method(_, _): "method_" + digest(reference(index));
			case Object(name, _, _, _, _, _): part(text(name));
			case Structure(name, _, _, _, _): part("struct_" + text(name));
			case Virtual(name, _): text(name) == ""
				? "virtual_" + digest(reference(index)) : part("virtual_" + text(name));
			case Enum(name, _, _): part("enum_" + text(name));
		};

	/** What a type is, naming the types it refers to by their references in turn: the same text in every build. */
	function reference(index:Int):String {
		var cached = index < references.length ? references[index] : null;
		if (cached != null)
			return cached;
		if (visiting.exists(index))
			return "#recursive";
		visiting.set(index, true);
		var result = switch code.types[index] {
			case Simple(kind): Std.string(kind);
			case EnumTag(boxed, _): "tag<" + reference(boxed) + ">";
			case Parameterized(kind, parameter): Std.string(kind) + "<" + reference(parameter) + ">";
			case Abstract(name): "abstract " + text(name);
			case Function(arguments,
				result): "fun(" + [for (argument in arguments) reference(argument)].join(",") + "):"
				+ reference(result);
			case Method(arguments,
				result): "method(" + [for (argument in arguments) reference(argument)].join(",") + "):"
				+ reference(result);
			case Object(name, _, _, _, _, _): "object " + text(name);
			case Structure(name, _, _, _, _): "struct " + text(name);
			case Virtual(name, fields): "virtual " + text(name) + "{"
				+ [for (field in fields) text(field.name) + ":" + reference(field.type)].join(",") + "}";
			case Enum(name, _, _): "enum " + text(name);
		};
		visiting.remove(index);
		references[index] = result;
		return result;
	}

	/** A type's reference and what it holds, which tells apart two types of one name. */
	function typeContent(index:Int):String
		return reference(index) + switch code.types[index] {
			case Object(_, base, _, fields, _, _):
				" : " + (base >= 0 ? reference(base) : "") + "{"
					+ [for (field in fields) text(field.name) + ":" + reference(field.type)].join(",") + "}";
			case Structure(_, _, fields, _, _):
				"{" + [for (field in fields) text(field.name) + ":" + reference(field.type)].join(",") + "}";
			case Enum(_, _, constructors):
				"{" + [
					for (constructor in constructors)
						text(constructor.name) + "("
						+ [for (parameter in constructor.params) reference(parameter)].join(",") + ")"
				].join(",") + "}";
			default: "";
		};
}
