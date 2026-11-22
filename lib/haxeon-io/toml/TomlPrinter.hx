package toml;

/**
 * Writes the values `TomlParser` reads (and `haxe.Json.parse` gives) as a TOML document. The top-level object's objects become
 * `[section]`s, and an object in a section that holds further objects a `[section.name]`; any other object is an inline table, so
 * `{"dependencies": {"a": {"path": "../a"}}}` prints as `[dependencies]` then `a = { path = "../a" }`.
 *
 * Keys print in `order` where they are listed there (at any depth), then the rest alphabetically, so the output does not depend on
 * the runtime's field order. TOML has no null: a null field is left out, and a null in an array is an error. An integral float of more
 * than 32 bits prints as an integer, as `TomlParser` reads such integers into floats; a runtime that cannot tell `1.0` from `1`
 * (stock HashLink) prints both as `1`.
 */
class TomlPrinter {
	public static function print(value:Dynamic, ?order:Array<String>):String {
		if (!isTable(value))
			throw new haxe.Exception("a TOML document is a table");
		var printer = new TomlPrinter(order == null ? [] : order);
		printer.table(value, [], true);
		return printer.output.toString();
	}

	final order:Array<String>;
	final output = new StringBuf();

	function new(order:Array<String>)
		this.order = order;

	/** The keys of `value` that print as `key = value` lines, then the sections under `path`. */
	function table(value:Dynamic, path:Array<String>, root:Bool):Void {
		var names = sortedFields(value), sections = [];
		for (name in names) {
			var field:Dynamic = Reflect.field(value, name);
			if (field == null)
				continue;
			if (isTable(field) && (root || holdsTable(field)))
				sections.push(name);
			else {
				output.add(key(name));
				output.add(" = ");
				write(field);
				output.add("\n");
			}
		}
		for (name in sections) {
			var sectionPath = path.concat([name]);
			if (output.length > 0)
				output.add("\n");
			output.add("[" + [for (part in sectionPath) key(part)].join(".") + "]\n");
			table(Reflect.field(value, name), sectionPath, false);
		}
	}

	function write(value:Dynamic):Void {
		if (Std.isOfType(value, String))
			string(value);
		else if (Std.isOfType(value, Bool))
			output.add(value ? "true" : "false");
		else if (Std.isOfType(value, TomlDateTime))
			output.add((value:TomlDateTime).text);
		else if (Std.isOfType(value, Int) || Std.isOfType(value, Float))
			output.add(number(value));
		else if (Std.isOfType(value, Array)) {
			var items:Array<Dynamic> = value;
			output.add("[");
			for (index in 0...items.length) {
				if (items[index] == null)
					throw new haxe.Exception("TOML has no null: an array holds one");
				if (index > 0)
					output.add(", ");
				write(items[index]);
			}
			output.add("]");
		} else if (isTable(value)) {
			var first = true;
			output.add("{");
			for (name in sortedFields(value)) {
				var field:Dynamic = Reflect.field(value, name);
				if (field == null)
					continue;
				output.add(first ? " " : ", ");
				first = false;
				output.add(key(name));
				output.add(" = ");
				write(field);
			}
			output.add(first ? "}" : " }");
		} else
			throw new haxe.Exception('cannot write ${Std.string(value)} as TOML');
	}

	static function number(value:Dynamic):String {
		if (Math.isNaN(value))
			return "nan";
		if (!Math.isFinite(value))
			return value > 0 ? "inf" : "-inf";
		if (Math.ffloor(value) == value && Math.abs(value) <= 9007199254740992.0
			&& (Std.isOfType(value, Int) || Math.abs(value) > 2147483647.0))
			return (value < 0 ? "-" : "") + integerDigits(Math.abs(value));
		var text = Std.string(value);
		return text.indexOf(".") >= 0 || text.indexOf("e") >= 0 || text.indexOf("E") >= 0 ? text : text + ".0";
	}

	static function integerDigits(value:Float):String {
		var digits = "";
		while (value >= 1) {
			var rest = Math.ffloor(value / 10);
			digits = Std.string(Std.int(value - rest * 10)) + digits;
			value = rest;
		}
		return digits == "" ? "0" : digits;
	}

	function string(value:String):Void {
		output.add("\"");
		var run = 0;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index), escaped = switch code {
				case "\"".code: "\\\"";
				case "\\".code: "\\\\";
				case "\n".code: "\\n";
				case "\r".code: "\\r";
				case "\t".code: "\\t";
				case 8: "\\b";
				case 12: "\\f";
				case _ if (code < 0x20 || code == 0x7F): "\\u00" + StringTools.hex(code, 2);
				case _: null;
			}
			if (escaped != null) {
				output.add(value.substring(run, index));
				output.add(escaped);
				run = index + 1;
			}
		}
		output.add(value.substring(run, value.length));
		output.add("\"");
	}

	static function key(name:String):String {
		if (name.length == 0)
			return "\"\"";
		for (index in 0...name.length) {
			var code = name.charCodeAt(index);
			if (!(code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code
				|| code >= "0".code && code <= "9".code || code == "_".code || code == "-".code)) {
				var printer = new TomlPrinter([]);
				printer.string(name);
				return printer.output.toString();
			}
		}
		return name;
	}

	function sortedFields(value:Dynamic):Array<String> {
		var names = Reflect.fields(value);
		names.sort((left, right) -> {
			var leftRank = order.indexOf(left), rightRank = order.indexOf(right);
			if (leftRank >= 0 || rightRank >= 0)
				return leftRank < 0 ? 1 : rightRank < 0 ? -1 : leftRank - rightRank;
			return left < right ? -1 : left > right ? 1 : 0;
		});
		return names;
	}

	static function holdsTable(value:Dynamic):Bool {
		for (name in Reflect.fields(value))
			if (isTable(Reflect.field(value, name)))
				return true;
		return false;
	}

	static function isTable(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, String) && !Std.isOfType(value, Array)
			&& !Std.isOfType(value, TomlDateTime);
}
