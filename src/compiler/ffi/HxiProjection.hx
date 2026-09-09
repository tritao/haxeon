package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrType;
import compiler.ffi.HxiModel.HxiPointerOwnership;

/** Projects bridgeable HXI functions into a synthetic, source-visible module. */
class HxiProjection {
	public static function cNatives(model:HxiInterface):Array<IrCNative> {
		var library = model.library;
		if (library == null)
			return [];
		var result:Array<IrCNative> = [];
		for (fn in HxiAbi.forInterface(model).functions()) {
			var arguments:Array<IrType> = [],
				codes:Array<String> = [],
				supported = true;
			for (argument in fn.arguments) {
				var value = project(argument, false);
				if (value == null) {
					supported = false;
					break;
				}
				arguments.push(irType(value.code, false, value.nativePointer));
				codes.push(Std.string(value.code));
			}
			var returnValue = project(fn.result, true);
			var ownership = switch fn.resultPolicy.ownership {
				case Unspecified: {kind: "unspecified", release: null};
				case Borrowed: {kind: "borrowed", release: null};
				case Owned(release): {kind: "owned", release: release};
			};
			if (supported && returnValue != null)
				result.push({
					name: model.name + "." + fn.name,
					library: library,
					symbol: fn.symbol,
					signature: codes.join(",") + ">" + returnValue.code,
					arguments: arguments,
					result: irType(returnValue.code, true),
					pointerOwnership: ownership.kind,
					pointerRelease: ownership.release,
					pointerLength: fn.resultPolicy.length
				});
		}
		return result;
	}

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
			var resultType = result.code == 11 ? 'hl.Abstract<"native_pointer">' : result.haxeType;
			output.add('):$resultType;\n');
		}
		return output.toString();
	}

	static function project(value:HxiAbiValue, allowVoid:Bool):Null<{haxeType:String, code:Int, nativePointer:Bool}>
		return switch value {
			case VoidValue: allowVoid ? {haxeType: "Void", code: 0, nativePointer: false} : null;
			case IntegerValue(64, sign): {haxeType: "haxe.Int64", code: sign == Unsigned ? 8 : 7, nativePointer: false};
			case IntegerValue(bits, sign) if (bits <= 32):
				var unsigned = sign == Unsigned || sign == PlainChar;
				{
					haxeType: "Int",
					nativePointer: false,
					code: switch bits {
						case 8: unsigned ? 2 : 1;
						case 16: unsigned ? 4 : 3;
						default: unsigned ? 6 : 5;
					}
				};
			case FloatValue(32): {haxeType: "Float", code: 9, nativePointer: false};
			case FloatValue(64): {haxeType: "Float", code: 10, nativePointer: false};
			case PointerValue(_, nullable, opaque): {
					haxeType: opaque ? (nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">') : (nullable ? "Null<haxe.io.Bytes>" : "haxe.io.Bytes"),
					code: 11,
					nativePointer: opaque
				};
			case _: null;
		};

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');

	static function irType(code:Int, result:Bool = false, nativePointer:Bool = false):IrType
		return switch code {
			case 0: Void;
			case 7 | 8: I64;
			case 9 | 10: F64;
			case 11: Abstract(result || nativePointer ? "native_pointer" : "realtime_bytes");
			default: I32;
		};
}
