package build.shader;

import haxe.io.Bytes;
import sys.io.File;

class ShaderReflection {
	/** Read the pinned compiler's indentation-only reflection format. */
	public static function read(path:String):Dynamic {
		var rows = [];
		for (line in File.getContent(path).split("\n")) {
			var text = StringTools.trim(line);
			if (text != "")
				rows.push({indent: line.length - StringTools.ltrim(line).length, text: text});
		}
		var cursor = 0;
		function node(indent:Int):Dynamic {
			var list = rows[cursor].text == "-";
			var result:Dynamic = list ? [] : {};
			while (cursor < rows.length && rows[cursor].indent == indent) {
				var text = rows[cursor++].text;
				if (list) {
					if (text != "-" || cursor == rows.length || rows[cursor].indent <= indent)
						throw "Invalid shader reflection list";
					(cast result:Array<Dynamic>).push(node(rows[cursor].indent));
					continue;
				}
				var colon = text.indexOf(":");
				if (colon <= 0)
					throw "Invalid shader reflection field";
				var key = text.substr(0, colon), value = StringTools.trim(text.substr(colon + 1));
				if (value == "" && cursor < rows.length && rows[cursor].indent > indent)
					Reflect.setField(result, key, node(rows[cursor].indent));
				else
					Reflect.setField(result, key, switch value {
						case "true": true;
						case "false": false;
						case _ if (~/^-?[0-9]+$/.match(value)): Std.parseInt(value);
						case _: value;
					});
			}
			return result;
		}
		if (rows.length == 0)
			throw "Empty shader reflection";
		var result = node(rows[0].indent);
		if (cursor != rows.length)
			throw "Invalid shader reflection indentation";
		return result;
	}

	public static function rows(value:Dynamic, field:String):Array<Dynamic> {
		var entries = Reflect.field(value, field);
		return entries == null ? [] : cast entries;
	}

	/** Recover original std140 members from the SPIR-V before GLSL flattening. */
	public static function uniformMembers(path:String):Map<String, Array<Dynamic>> {
		var bytes = File.getBytes(path),
			words = [for (index in 0...Std.int(bytes.length / 4)) bytes.getInt32(index * 4)];
		var names:Map<Int, String> = [],
			members:Map<String, String> = [],
			types:Map<Int, {opcode:Int, args:Array<Int>}> = [],
			constants:Map<Int, Int> = [],
			offsets:Map<String, Int> = [],
			strides:Map<Int, Int> = [],
			blocks:Array<Int> = [];
		var cursor = 5;
		while (cursor < words.length) {
			var count = words[cursor] >>> 16, opcode = words[cursor] & 0xffff;
			if (count == 0 || cursor + count > words.length)
				throw "Invalid shader SPIR-V";
			var args = words.slice(cursor + 1, cursor + count);
			switch opcode {
				case 5: names.set(args[0], literal(bytes, cursor + 2, count - 2));
				case 6: members.set(args[0] + ":" + args[1], literal(bytes, cursor + 3, count - 3));
				case 21 | 22 | 23 | 24 | 28 | 30: types.set(args[0], {opcode: opcode, args: args.slice(1)});
				case 43: constants.set(args[1], args[2]);
				case 71 if (args[1] == 2): blocks.push(args[0]);
				case 71 if (args[1] == 6): strides.set(args[0], args[2]);
				case 72 if (args[2] == 35): offsets.set(args[0] + ":" + args[1], args[3]);
				case _:
			}
			cursor += count;
		}
		function kind(id:Int):String {
			var type = types.get(id);
			if (type == null)
				throw "Missing SPIR-V type in " + path;
			return switch type.opcode {
				case 21 if (type.args[0] == 32 && type.args[1] == 1): "int";
				case 22 if (type.args[0] == 32): "float";
				case 23: (kind(type.args[0]) == "int" ? "ivec" : "vec") + type.args[1];
				case 24 if (type.args[1] == 4 && kind(type.args[0]) == "vec4"): "mat4";
				case _: throw "Unsupported std140 member type in " + path;
			};
		}
		var result:Map<String, Array<Dynamic>> = [];
		for (block in blocks) {
			var type = types.get(block), name = names.get(block);
			if (type == null || type.opcode != 30 || name == null
				|| Lambda.exists([for (index in 0...type.args.length) index],
				index -> !offsets.exists(block + ":" + index)))
				continue;
			var fields:Array<Dynamic> = [];
			for (index => id in type.args) {
				var key = block + ":" + index, item = types.get(id);
				if (item == null)
					throw "Missing SPIR-V member type in " + path;
				var stride = strides.get(id), count = item.opcode == 28 ? constants.get(item.args[1]) : 1;
				fields.push({
					name: members.get(key),
					type: kind(item.opcode == 28 ? item.args[0] : id),
					offset: offsets.get(key),
					arrayCount: count,
					arrayStride: stride
				});
			}
			result.set(name, fields);
		}
		return result;
	}

	static function literal(bytes:Bytes, start:Int, count:Int):String {
		var text = bytes.getString(start * 4, count * 4);
		var end = text.indexOf(String.fromCharCode(0));
		return end < 0 ? text : text.substr(0, end);
	}
}
