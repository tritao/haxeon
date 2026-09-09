package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiModel.HxiInterface;

/** Projects bridgeable HXI functions into a synthetic, source-visible module. */
class HxiProjection {
	public static function source(model:HxiInterface):String {
		var library = model.library;
		if (library == null)
			return "";
		var abi = HxiAbi.forInterface(model), output = new StringBuf();
		output.add('// Generated semantic projection of ${model.name}. Do not edit.\n');
		for (fn in abi.functions()) {
			var argumentTypes:Array<String> = [],
				codes:Array<String> = [],
				supported = true;
			for (argument in fn.arguments) {
				var projected = project(argument, false);
				if (projected == null) {
					supported = false;
					break;
				}
				argumentTypes.push(projected.haxeType);
				codes.push(Std.string(projected.code));
			}
			var result = project(fn.result, true);
			if (!supported || result == null)
				continue;
			var signature = codes.join(",") + ">" + result.code;
			output.add('@:cNative("${escape(library)}", "${escape(fn.symbol)}", "$signature")\n');
			output.add('extern function ${fn.name}(');
			output.add([for (index in 0...argumentTypes.length) 'arg$index:${argumentTypes[index]}'].join(", "));
			output.add('):${result.haxeType};\n');
		}
		return output.toString();
	}

	static function project(value:HxiAbiValue, allowVoid:Bool):Null<{haxeType:String, code:Int}>
		return switch value {
			case VoidValue: allowVoid ? {haxeType: "Void", code: 0} : null;
			case IntegerValue(bits, sign) if (bits <= 32):
				var unsigned = sign == Unsigned || sign == PlainChar;
				{
					haxeType: "Int",
					code: switch bits {
						case 8: unsigned ? 2 : 1;
						case 16: unsigned ? 4 : 3;
						default: unsigned ? 6 : 5;
					}
				};
			case FloatValue(32): {haxeType: "Float", code: 9};
			case FloatValue(64): {haxeType: "Float", code: 10};
			case PointerValue(_): {haxeType: "haxe.io.Bytes", code: 11};
			case _: null;
		};

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');
}
