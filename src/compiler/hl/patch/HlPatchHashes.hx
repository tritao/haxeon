package compiler.hl.patch;

import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlType as HashLinkType;

/** HashLink-compatible hashes for the immutable symbol prefixes in an HLP. */
class HlPatchHashes {
	public static function ints(values:Array<Int>, count:Int):Int {
		var hash:Int = cast 0x811C9DC5;
		for (i in 0...count)
			hash = hashBytes(intBytes(values[i]), hash);
		return hash;
	}

	public static function floats(values:Array<Float>, count:Int):Int {
		var hash:Int = cast 0x811C9DC5;
		for (i in 0...count) {
			var out = new BytesOutput();
			out.bigEndian = false;
			out.writeDouble(values[i]);
			hash = hashBytes(out.getBytes(), hash);
		}
		return hash;
	}

	public static function strings(values:Array<String>, count:Int):Int {
		var hash:Int = cast 0x811C9DC5;
		for (i in 0...count) {
			var bytes = HaxeBytes.ofString(values[i]);
			hash = hashBytes(intBytes(bytes.length), hash);
			hash = hashBytes(bytes, hash);
		}
		return hash;
	}

	public static function types(values:Array<HlTypeDef>, count:Int):Int {
		var hash:Int = cast 0x811C9DC5;
		for (i in 0...count)
			switch values[i] {
				case Simple(kind):
					hash = hashBytes(intBytes(kind), hash);
				case Parameterized(kind, parameter):
					hash = hashBytes(intBytes(kind), hash);
					hash = hashBytes(intBytes(parameter), hash);
				case Abstract(name):
					hash = hashBytes(intBytes(HashLinkType.Abstract), hash);
					hash = hashBytes(intBytes(name), hash);
				case Function(args, result):
					hash = hashBytes(intBytes(HashLinkType.Fun), hash);
					hash = hashBytes(intBytes(args.length), hash);
					for (argument in args)
						hash = hashBytes(intBytes(argument), hash);
					hash = hashBytes(intBytes(result), hash);
				case Method(args, result):
					hash = hashBytes(intBytes(HashLinkType.Method), hash);
					hash = hashBytes(intBytes(args.length), hash);
					for (argument in args)
						hash = hashBytes(intBytes(argument), hash);
					hash = hashBytes(intBytes(result), hash);
				case Object(name, base, global, fields, methods, bindings):
					hash = hashBytes(intBytes(HashLinkType.Obj), hash);
					hash = hashBytes(intBytes(name), hash);
					hash = hashBytes(intBytes(base), hash);
					hash = hashBytes(intBytes(global), hash);
					hash = hashBytes(intBytes(fields.length), hash);
					for (field in fields) {
						hash = hashBytes(intBytes(field.name), hash);
						hash = hashBytes(intBytes(field.type), hash);
					}
					hash = hashBytes(intBytes(methods.length), hash);
					for (method in methods) {
						hash = hashBytes(intBytes(method.name), hash);
						hash = hashBytes(intBytes(method.functionIndex), hash);
						hash = hashBytes(intBytes(method.prototype), hash);
					}
					hash = hashBytes(intBytes(bindings.length), hash);
					for (binding in bindings)
						hash = hashBytes(intBytes(binding), hash);
				case Structure(name, global, fields, methods, bindings):
					hash = hashBytes(intBytes(HashLinkType.Struct), hash);
					hash = hashBytes(intBytes(name), hash);
					hash = hashBytes(intBytes(-1), hash);
					hash = hashBytes(intBytes(global), hash);
					hash = hashBytes(intBytes(fields.length), hash);
					for (field in fields) {
						hash = hashBytes(intBytes(field.name), hash);
						hash = hashBytes(intBytes(field.type), hash);
					}
					hash = hashBytes(intBytes(methods.length), hash);
					for (method in methods) {
						hash = hashBytes(intBytes(method.name), hash);
						hash = hashBytes(intBytes(method.functionIndex), hash);
						hash = hashBytes(intBytes(method.prototype), hash);
					}
					hash = hashBytes(intBytes(bindings.length), hash);
					for (binding in bindings)
						hash = hashBytes(intBytes(binding), hash);
				case Virtual(fields):
					hash = hashBytes(intBytes(HashLinkType.Virtual), hash);
					hash = hashBytes(intBytes(fields.length), hash);
					for (field in fields) {
						hash = hashBytes(intBytes(field.name), hash);
						hash = hashBytes(intBytes(field.type), hash);
					}
				case Enum(name, global, constructors):
					hash = hashBytes(intBytes(HashLinkType.Enum), hash);
					hash = hashBytes(intBytes(name), hash);
					hash = hashBytes(intBytes(global), hash);
					hash = hashBytes(intBytes(constructors.length), hash);
					for (constructor in constructors) {
						hash = hashBytes(intBytes(constructor.name), hash);
						hash = hashBytes(intBytes(constructor.params.length), hash);
						for (parameter in constructor.params)
							hash = hashBytes(intBytes(parameter), hash);
					}
			}
		return hash;
	}

	static function hashBytes(bytes:HaxeBytes, hash:Int):Int {
		var result = hash;
		for (i in 0...bytes.length)
			result = (result ^ bytes.get(i)) * 16777619;
		return result;
	}

	static function intBytes(value:Int):HaxeBytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeInt32(value);
		return out.getBytes();
	}
}
