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
		var result:Array<IrCNative> = [],
			declarations:Map<String, HxiDeclaration> = [];
		for (declaration in model.declarations)
			switch declaration {
				case Opaque(name, _) | Alias(name, _, _) | Structure(name, _, _, _, _) | Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _):
					declarations.set(name, declaration);
				case _:
			}
		var abi = HxiAbi.forInterface(model);
		for (fn in abi.functions()) {
			var arguments:Array<IrType> = [],
				codes:Array<String> = [],
				supported = true;
			for (argument in fn.arguments) {
				var value = project(argument, false);
				if (value == null) {
					supported = false;
					break;
				}
				var nativeAbstract = switch argument {
					case CallbackValue(_, _, _, _): "native_callback";
					case _: value.nativePointer ? "native_pointer" : null;
				};
				arguments.push(irType(value.code, false, nativeAbstract));
				codes.push(abiDescriptor(argument, declarations, abi));
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
					signature: callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi), fn.callConvention),
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
		var usesNestedStructures = false,
			usesPointerFields = false,
			hasCallbacks = false;
		for (declaration in model.declarations)
			switch declaration {
				case Opaque(name, _) | Alias(name, _, _) | Structure(name, _, _, _, _) | Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _):
					declarations.set(name, declaration);
				case _:
			}
		output.add('// Generated semantic projection of ${model.name}. Do not edit.\n');
		for (declaration in model.declarations)
			switch declaration {
				case Callback(_, _, _, _, _):
					hasCallbacks = true;
				case _:
			}
		if (hasCallbacks)
			output.add('enum abstract HxiCallbackError(Int) from Int to Int { var None = 0; var Exception = 1; var WrongThread = 2; var PointerContract = 3; var AggregateContract = 4; var StringContract = 5; }\n');
		for (declaration in model.declarations)
			switch declaration {
				case Callback(name, parameters, result, callConvention, _):
					var argumentTypes = [], codes = [], pointerSizes = [], pointerNullable = [], supported = true;
					for (parameter in parameters) {
						var classified = abi.classify(parameter.type),
							value = callbackProject(classified);
						if (value == null) {
							supported = false;
							break;
						}
						argumentTypes.push('${parameter.name}:${value.haxeType}');
						codes.push(abiDescriptor(classified, declarations, abi));
						switch classified {
							case PointerValue(_, nullable, _, structure):
								var declaration = structure == null ? null : declarations.get(structure),
									size = switch declaration {
										case Structure(_, value, _, _, _): value;
										case _: 0;
									};
								pointerSizes.push(Std.string(size));
								pointerNullable.push(nullable ? "1" : "0");
							case Utf8Value(nullable):
								pointerSizes.push("0");
								pointerNullable.push(nullable ? "1" : "0");
							case _:
								pointerSizes.push("0");
								pointerNullable.push("0");
						}
					}
					var returnValue = project(abi.classify(result, true), true);
					if (!supported || returnValue == null)
						continue;
					var classifiedResult = abi.classify(result, true);
					var signature = callSignature(codes.join(",") + ">" + abiDescriptor(classifiedResult, declarations, abi), callConvention);
					output.add('typedef $name = (${argumentTypes.join(", ")})->${returnValue.haxeType};\n');
					output.add('abstract ${name}Callback(hl.Abstract<"native_callback">) {\n');
					output.add('\tpublic inline function new(callback:$name) this = ${model.name}.__hxi_callback_create(haxe.io.Bytes.ofString("$signature"), haxe.io.Bytes.ofString("${pointerSizes.join(",")}"), haxe.io.Bytes.ofString("${pointerNullable.join(",")}"), callback);\n');
					output.add('\tpublic inline function close():Bool return ${model.name}.__hxi_callback_close_$name(this);\n');
					output.add('\tpublic inline function errorKind():HxiCallbackError return ${model.name}.__hxi_callback_error_kind_$name(this);\n');
					output.add('\tpublic inline function takeError():Null<haxe.io.Bytes> return ${model.name}.__hxi_callback_take_error_$name(this);\n');
					output.add('}\n');
					output.add('@:hlNative("realtime_runtime", "native_callback_close") extern function __hxi_callback_close_$name(callback:${name}Callback):Bool;\n');
					output.add('@:hlNative("realtime_runtime", "native_callback_error_kind") extern function __hxi_callback_error_kind_$name(callback:${name}Callback):Int;\n');
					output.add('@:hlNative("realtime_runtime", "native_callback_take_error") extern function __hxi_callback_take_error_$name(callback:${name}Callback):Null<haxe.io.Bytes>;\n');
				case _:
			}
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
		if (hasCallbacks) {
			output.add('@:hlNative("realtime_runtime", "native_callback_create") extern function __hxi_callback_create(signature:haxe.io.Bytes, pointerSizes:haxe.io.Bytes, pointerNullable:haxe.io.Bytes, callback:Dynamic):hl.Abstract<"native_callback">;\n');
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
				codes.push(abiDescriptor(argument, declarations, abi));
			}
			var result = project(fn.result, true);
			if (!supported || result == null)
				continue;
			var signature = callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi), fn.callConvention);
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
			case CallbackValue(name, _, _, nullable): {
					haxeType: nullable ? 'Null<${name}Callback>' : name + "Callback",
					code: 11,
					nativePointer: true,
					nullable: false
				};
			case AggregateValue(name, _, _): {
					haxeType: name,
					code: 12,
					nativePointer: false,
					nullable: false
				};
			case Utf8Value(nullable): {
					haxeType: nullable ? "Null<String>" : "String",
					code: 13,
					nativePointer: false,
					nullable: nullable
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

	static function callbackProject(value:HxiAbiValue):Null<{
		haxeType:String,
		code:Int,
		nativePointer:Bool,
		nullable:Bool
	}>
		return switch value {
			case PointerValue(_, nullable, _, structure): {
					haxeType: structure == null ? (nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">') : (nullable ? 'Null<$structure>' : structure),
					code: 11,
					nativePointer: structure == null,
					nullable: nullable
				};
			case _: project(value, false);
		};

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');

	static function callSignature(signature:String, convention:String):String
		return convention == "cdecl" ? signature : signature + "@" + convention;

	static function abiDescriptor(value:HxiAbiValue, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):String
		return switch value {
			case AggregateValue(name, size, align):
				switch declarations.get(name) {
					case Structure(_, _, _, fields, _):
						var ordered = fields.copy();
						ordered.sort((left, right) -> left.offset - right.offset);
						var cursor = 0, naturalAlign = 1;
						for (field in ordered) {
							var layout = abiLayout(field.type, declarations, abi);
							cursor = (cursor + layout.align - 1) & -layout.align;
							if (field.offset != cursor)
								throw 'HXI structure "$name" cannot be passed by value because its layout is not a natural C struct';
							cursor += layout.size;
							naturalAlign = Std.int(Math.max(naturalAlign, layout.align));
						}
						if (naturalAlign != align || ((cursor + naturalAlign - 1) & -naturalAlign) != size)
							throw 'HXI structure "$name" cannot be passed by value because its layout is not a natural C struct';
						'{$size;$align;${[for (field in ordered) for (entry in fieldDescriptors(field.type, declarations, abi)) entry].join(",")}}';
					case _: throw 'Missing HXI structure "$name"';
				}
			case VoidValue: "0";
			case IntegerValue(64, sign): sign == Unsigned ? "8" : "7";
			case IntegerValue(bits, sign): Std.string(switch bits {
					case 8: sign == Signed ? 1 : 2;
					case 16: sign == Signed ? 3 : 4;
					case _: sign == Signed ? 5 : 6;
				});
			case EnumerationValue(_, bits, sign): Std.string(switch bits {
					case 8: sign == Signed ? 1 : 2;
					case 16: sign == Signed ? 3 : 4;
					case _: sign == Signed ? 5 : 6;
				});
			case FloatValue(32): "9";
			case FloatValue(64): "10";
			case FloatValue(bits): throw 'Unsupported $bits-bit floating-point ABI value';
			case PointerValue(_, _, _, _) | CallbackValue(_, _, _, _): "11";
			case Utf8Value(nullable): nullable ? "14" : "13";
		};

	static function abiLayout(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):{size:Int, align:Int}
		return switch type {
			case Const(element): abiLayout(element, declarations, abi);
			case Array(element, length):
				var item = abiLayout(element, declarations, abi);
				{size: item.size * length, align: item.align};
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): abiLayout(target, declarations, abi);
					case _: valueLayout(abi.classify(type), abi);
				}
			case _: valueLayout(abi.classify(type), abi);
		};

	static function valueLayout(value:HxiAbiValue, abi:HxiAbi):{size:Int, align:Int}
		return switch value {
			case IntegerValue(bits, _) | EnumerationValue(_, bits, _) | FloatValue(bits):
				var size = Std.int(bits / 8);
				{size: size, align: Std.int(Math.min(size, abi.pointerBits / 8))};
			case PointerValue(_, _, _, _) | CallbackValue(_, _, _, _):
				var size = Std.int(abi.pointerBits / 8);
				{size: size, align: size};
			case Utf8Value(_):
				var size = Std.int(abi.pointerBits / 8);
				{size: size, align: size};
			case AggregateValue(_, size, align): {size: size, align: align};
			case VoidValue: throw "Void field has no C layout";
		};

	static function fieldDescriptors(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):Array<String>
		return switch type {
			case Const(element): fieldDescriptors(element, declarations, abi);
			case Array(element, length): [
					for (_ in 0...length)
						for (entry in fieldDescriptors(element, declarations, abi))
							entry
				];
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): fieldDescriptors(target, declarations, abi);
					case Structure(_, _, _, _, _): [abiDescriptor(abi.classify(type), declarations, abi)];
					case _: [abiDescriptor(abi.classify(type), declarations, abi)];
				}
			case _: [abiDescriptor(abi.classify(type), declarations, abi)];
		};

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

	static function irType(code:Int, result:Bool = false, nativeAbstract:Null<String> = null):IrType
		return switch code {
			case 0: Void;
			case 7 | 8: I64;
			case 9 | 10: F64;
			case 11: Abstract(result ? "native_pointer" : nativeAbstract == null ? "realtime_bytes" : nativeAbstract);
			case 12: Abstract("realtime_bytes");
			case 13: Bytes;
			default: I32;
		};
}
