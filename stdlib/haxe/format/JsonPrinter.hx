/* Derived from the Haxe standard library JsonPrinter under the MIT license. */
package haxe.format;

@:hlNative("haxeon_runtime", "__json_value_kind")
extern function jsonValueKind(value:Dynamic):Int;

@:hlNative("haxeon_runtime", "__reflect_array_get")
extern function jsonArrayGet(value:Dynamic, index:Int):Dynamic;

class JsonPrinter {
	public static function print(value:Dynamic, ?replacer:(key:Dynamic, value:Dynamic)->Dynamic, ?space:String):String {
		var printer = new JsonPrinter(replacer, space);
		printer.write("", value);
		return printer.output.toString();
	}

	final output = new StringBuf();
	final stack:Array<Dynamic> = [];
	final replacer:Null<(key:Dynamic, value:Dynamic)->Dynamic>;
	final indent:String;
	var depth:Int = 0;

	function new(replacer:Null<(key:Dynamic, value:Dynamic)->Dynamic>, space:Null<String>) {
		this.replacer = replacer;
		this.indent = space == null ? "" : space;
	}

	function write(key:Dynamic, original:Dynamic):Void {
		var value = replacer == null ? original : replacer(key, original);
		switch jsonValueKind(value) {
			case 0: output.add("null");
			case 1: quote(cast(value, String));
			case 2: output.add(cast(value, Bool) ? "true" : "false");
			case 3: output.add(Std.string(value));
			case 4:
				var number = cast(value, Float);
				output.add(Math.isFinite(number) ? Std.string(number) : "null");
			case 5: writeArray(cast(value, Array<Dynamic>));
			case 6: throw "Cannot encode function as JSON";
			default: writeObject(value);
		}
	}

	function writeArray(value:Array<Dynamic>):Void {
		enter(value);
		output.add("[");
		depth++;
		for (index in 0...value.length) {
			if (index > 0) output.add(",");
			line();
			write(index, jsonArrayGet(value, index));
		}
		depth--;
		if (value.length > 0) line();
		output.add("]");
		stack.pop();
	}

	function writeObject(value:Dynamic):Void {
		enter(value);
		var fields = Reflect.fields(value);
		output.add("{");
		depth++;
		for (index in 0...fields.length) {
			if (index > 0) output.add(",");
			line();
			var field = fields[index];
			quote(field);
			output.add(indent.length == 0 ? ":" : ": ");
			write(field, Reflect.field(value, field));
		}
		depth--;
		if (fields.length > 0) line();
		output.add("}");
		stack.pop();
	}

	function enter(value:Dynamic):Void {
		for (active in stack) if (active == value) throw "Cyclic value cannot be encoded as JSON";
		stack.push(value);
	}

	function line():Void {
		if (indent.length == 0) return;
		output.add("\n");
		for (_ in 0...depth) output.add(indent);
	}

	function quote(value:String):Void {
		output.add('"');
		var start = 0;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index), escaped:Null<String> = switch code {
				case 34: '\\"';
				case 92: '\\\\';
				case 8: '\\b';
				case 9: '\\t';
				case 10: '\\n';
				case 12: '\\f';
				case 13: '\\r';
				default: code < 32 ? '\\u00' + StringTools.hex(code, 2) : null;
			};
			if (escaped == null) continue;
			output.addSub(value, start, index - start);
			output.add(escaped);
			start = index + 1;
		}
		output.addSub(value, start, value.length - start);
		output.add('"');
	}
}
