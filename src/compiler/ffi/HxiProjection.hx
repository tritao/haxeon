package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDeclaration;
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
			var managedBytes = fn.resultPolicy.length != null;
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
					result: managedBytes ? Abstract("realtime_bytes") : irType(returnValue.code, true),
					pointerOwnership: ownership.kind,
					pointerRelease: ownership.release,
					pointerLength: fn.resultPolicy.length,
					pointerNullable: returnValue.nullable
				});
		}
		return result;
	}

	public static function source(model:HxiInterface):String {
		var library = model.library;
		if (library == null)
			return "";
		var abi = HxiAbi.forInterface(model), output = new StringBuf();
		var structAccesses:Map<String, {type:String, setterType:String}> = [],
			declarations:Map<String, HxiDeclaration> = [];
		var usesNestedStructures = false, usesPointerFields = false;
		for (declaration in model.declarations)
			switch declaration {
				case Opaque(name, _) | Alias(name, _, _) | Structure(name, _, _, _, _) | Enumeration(name, _, _, _, _):
					declarations.set(name, declaration);
				case _:
			}
		output.add('// Generated semantic projection of ${model.name}. Do not edit.\n');
		for (declaration in model.declarations)
			switch declaration {
				case Enumeration(name, representation, _, values, _):
					var underlying = project(abi.classify(representation), false);
					if (underlying == null)
						continue;
					output.add('enum abstract $name(${underlying.haxeType}) from ${underlying.haxeType} to ${underlying.haxeType} {\n');
					for (value in values)
						output.add('\tvar ${value.name} = ${value.value};\n');
					output.add('}\n');
				case _:
			}
		for (declaration in model.declarations)
			switch declaration {
				case Structure(name, size, _, fields, _):
					output.add('abstract $name(haxe.io.Bytes) from haxe.io.Bytes to haxe.io.Bytes {\n');
					output.add('\tpublic inline function new() this = haxe.io.Bytes.alloc($size);\n');
					for (field in fields) {
						var array = arrayType(field.type, declarations);
						if (array != null) {
							var nestedElement = structureType(array.element, declarations);
							if (nestedElement != null) {
								usesNestedStructures = true;
								output.add('\tpublic inline function get_${field.name}(index:Int):${nestedElement.name} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; return ${model.name}.__hxi_struct_slice(this, ${field.offset} + index * ${nestedElement.size}, ${nestedElement.size}); }\n');
								output.add('\tpublic inline function set_${field.name}(index:Int, value:${nestedElement.name}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; ${model.name}.__hxi_struct_copy(this, ${field.offset} + index * ${nestedElement.size}, value, ${nestedElement.size}); }\n');
								continue;
							}
							if (arrayType(array.element, declarations) != null)
								continue;
							var element = project(abi.classify(array.element), false);
							if (element == null || element.code == 11)
								continue;
							var arrayAccess = structAccess(element.code),
								stride = structSize(element.code);
							if (arrayAccess == null || stride == 0)
								continue;
							structAccesses.set(arrayAccess, {type: element.haxeType, setterType: element.haxeType});
							output.add('\tpublic inline function get_${field.name}(index:Int):${element.haxeType} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; return ${model.name}.__hxi_struct_get${arrayAccess}(this, ${field.offset} + index * $stride); }\n');
							output.add('\tpublic inline function set_${field.name}(index:Int, value:${element.haxeType}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; ${model.name}.__hxi_struct_set${arrayAccess}(this, ${field.offset} + index * $stride, value); }\n');
							if (element.code == 1 || element.code == 2) {
								usesNestedStructures = true;
								output.add('\tpublic inline function get_${field.name}_bytes():haxe.io.Bytes return ${model.name}.__hxi_struct_slice(this, ${field.offset}, ${array.length});\n');
								output.add('\tpublic inline function set_${field.name}_bytes(value:haxe.io.Bytes):Void ${model.name}.__hxi_struct_copy(this, ${field.offset}, value, ${array.length});\n');
							}
							continue;
						}
						var nested = structureType(field.type, declarations);
						if (nested != null) {
							usesNestedStructures = true;
							output.add('\tpublic inline function get_${field.name}():${nested.name} return ${model.name}.__hxi_struct_slice(this, ${field.offset}, ${nested.size});\n');
							output.add('\tpublic inline function set_${field.name}(value:${nested.name}):Void ${model.name}.__hxi_struct_copy(this, ${field.offset}, value, ${nested.size});\n');
							continue;
						}
						var value = project(abi.classify(field.type), false);
						if (value != null && value.code == 11 && value.nativePointer && field.ownership == Borrowed) {
							usesPointerFields = true;
							output.add('\tpublic inline function get_${field.name}():${value.haxeType} return ${model.name}.__hxi_struct_get_pointer(this, ${field.offset}, ${value.nullable});\n');
							output.add('\tpublic inline function set_${field.name}(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set_pointer(this, ${field.offset}, value, ${value.nullable});\n');
							continue;
						}
						if (value == null || value.code == 11)
							continue;
						var access = structAccess(value.code);
						if (access == null)
							continue;
						structAccesses.set(access, {type: value.haxeType, setterType: value.haxeType});
						output.add('\tpublic inline function get_${field.name}():${value.haxeType} return ${model.name}.__hxi_struct_get${access}(this, ${field.offset});\n');
						output.add('\tpublic inline function set_${field.name}(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set${access}(this, ${field.offset}, value);\n');
					}
					output.add('}\n');
				case _:
			}
		if (usesNestedStructures) {
			output.add('@:hlNative("realtime_runtime", "structSlice") extern function __hxi_struct_slice(bytes:haxe.io.Bytes, offset:Int, length:Int):haxe.io.Bytes;\n');
			output.add('@:hlNative("realtime_runtime", "structCopy") extern function __hxi_struct_copy(bytes:haxe.io.Bytes, offset:Int, value:haxe.io.Bytes, length:Int):Void;\n');
		}
		if (usesPointerFields) {
			output.add('@:hlNative("realtime_runtime", "structGetPointer") extern function __hxi_struct_get_pointer(bytes:haxe.io.Bytes, offset:Int, nullable:Bool):hl.Abstract<"native_pointer">;\n');
			output.add('@:hlNative("realtime_runtime", "structSetPointer") extern function __hxi_struct_set_pointer(bytes:haxe.io.Bytes, offset:Int, value:hl.Abstract<"native_pointer">, nullable:Bool):Void;\n');
		}
		for (access in ["I8", "U8", "I16", "U16", "I32", "I64", "F32", "F64"]) {
			var types = structAccesses.get(access);
			if (types == null)
				continue;
			output.add('@:hlNative("realtime_runtime", "get$access") extern function __hxi_struct_get$access(bytes:haxe.io.Bytes, offset:Int):${types.type};\n');
			output.add('@:hlNative("realtime_runtime", "set$access") extern function __hxi_struct_set$access(bytes:haxe.io.Bytes, offset:Int, value:${types.setterType}):Void;\n');
		}
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
			var resultType = result.code == 11 ? (fn.resultPolicy.length != null ? (result.nullable ? "Null<haxe.io.Bytes>" : "haxe.io.Bytes") : (result.nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">')) : result.haxeType;
			output.add('):$resultType;\n');
		}
		return output.toString();
	}

	static function project(value:HxiAbiValue, allowVoid:Bool):Null<{
		haxeType:String,
		code:Int,
		nativePointer:Bool,
		nullable:Bool
	}>
		return switch value {
			case VoidValue: allowVoid ? {
					haxeType: "Void",
					code: 0,
					nativePointer: false,
					nullable: false
				} : null;
			case IntegerValue(64, sign): {
					haxeType: "haxe.Int64",
					code: sign == Unsigned ? 8 : 7,
					nativePointer: false,
					nullable: false
				};
			case IntegerValue(bits, sign) if (bits <= 32):
				var unsigned = sign == Unsigned || sign == PlainChar;
				{
					haxeType: "Int",
					nativePointer: false,
					nullable: false,
					code: switch bits {
						case 8: unsigned ? 2 : 1;
						case 16: unsigned ? 4 : 3;
						default: unsigned ? 6 : 5;
					}
				};
			case EnumerationValue(name, bits, sign) if (bits <= 32):
				var unsigned = sign == Unsigned || sign == PlainChar;
				{
					haxeType: name,
					nativePointer: false,
					nullable: false,
					code: switch bits {
						case 8: unsigned ? 2 : 1;
						case 16: unsigned ? 4 : 3;
						default: unsigned ? 6 : 5;
					}
				};
			case FloatValue(32): {
					haxeType: "Float",
					code: 9,
					nativePointer: false,
					nullable: false
				};
			case FloatValue(64): {
					haxeType: "Float",
					code: 10,
					nativePointer: false,
					nullable: false
				};
			case PointerValue(_, nullable, opaque, structure): {
					haxeType: opaque ? (nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">') : structure != null ? (nullable ? 'Null<$structure>' : structure) : (nullable ? "Null<haxe.io.Bytes>" : "haxe.io.Bytes"),
					code: 11,
					nativePointer: opaque,
					nullable: nullable
				};
			case _: null;
		};

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');

	static function structAccess(code:Int):Null<String>
		return switch code {
			case 1: "I8";
			case 2: "U8";
			case 3: "I16";
			case 4: "U16";
			case 5 | 6: "I32";
			case 7 | 8: "I64";
			case 9: "F32";
			case 10: "F64";
			case _: null;
		};

	static function structSize(code:Int):Int
		return switch code {
			case 1 | 2: 1;
			case 3 | 4: 2;
			case 5 | 6 | 9: 4;
			case 7 | 8 | 10: 8;
			case _: 0;
		};

	static function arrayType(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>):Null<{
		element:compiler.ffi.HxiModel.HxiType,
		length:Int
	}>
		return switch type {
			case Const(element): arrayType(element, declarations);
			case Array(element, length): {element: element, length: length};
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): arrayType(target, declarations);
					case _: null;
				}
			case _: null;
		};

	static function structureType(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>):Null<{name:String, size:Int}>
		return switch type {
			case Const(element): structureType(element, declarations);
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): structureType(target, declarations);
					case Structure(_, size, _, _, _): {name: name, size: size};
					case _: null;
				}
			case _: null;
		};

	static function irType(code:Int, result:Bool = false, nativePointer:Bool = false):IrType
		return switch code {
			case 0: Void;
			case 7 | 8: I64;
			case 9 | 10: F64;
			case 11: Abstract(result || nativePointer ? "native_pointer" : "realtime_bytes");
			default: I32;
		};
}
