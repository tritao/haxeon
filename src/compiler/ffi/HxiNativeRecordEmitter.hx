package compiler.ffi;

import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiType;

/** Emits source-declared native records from an HXI structure model. */
class HxiNativeRecordEmitter {
	public static function emit(model:HxiInterface, packageName:String, ?typePrefix:String = "Native", ?fieldNames:Map<String, String>):String {
		var declarations:Map<String, HxiDeclaration> = [],
			structureNames:Map<String, String> = [],
			callbackNames:Map<String, String> = [];
		for (declaration in model.declarations) {
			var name = declarationName(declaration);
			declarations.set(name, declaration);
			if (isStructure(declaration))
				structureNames.set(name, className(name, typePrefix));
			if (isCallback(declaration))
				callbackNames.set(name, className(name, typePrefix));
		}
		var output = new StringBuf();
		output.add('package $packageName;\n\nimport runtime.memory.NativeFunctionPointer;\nimport runtime.memory.RawPtr;\n\n');
		for (declaration in model.declarations)
			switch declaration {
				case Callback(name, parameters, result, _, _):
					output.add('typedef ${callbackNames.get(name)} = ${callbackSignature(parameters, result, declarations, structureNames, callbackNames, [])};\n');
				case _:
			}
		if (model.declarations.length > 0)
			output.add("\n");
		for (declaration in model.declarations)
			switch declaration {
				case Structure(name, _, _, fields, _):
					emitStructure(output, name, fields, declarations, structureNames, callbackNames, typePrefix, fieldNames);
				case _:
			}
		return output.toString();
	}

	static function emitStructure(output:StringBuf, name:String, fields:Array<HxiField>, declarations:Map<String, HxiDeclaration>,
			structureNames:Map<String, String>, callbackNames:Map<String, String>, typePrefix:String, fieldNames:Null<Map<String, String>>):Void {
		var projectedName = structureNames.get(name),
			unionFields = [for (field in fields) if (field.metadata.exists("union")) field];
		if (unionFields.length > 0) {
			var unionOffset = unionFields[0].offset;
			for (field in unionFields)
				if (field.offset != unionOffset)
					throw 'Union fields in "$name" must share one offset';
			var unionName = projectedName + "UnionData";
			output.add('@:value @:repr("C") @:union\nclass $unionName {\n');
			for (field in unionFields)
				emitField(output, name, field, declarations, structureNames, callbackNames, fieldNames);
			output.add('}\n\n');
		}
		output.add('@:value @:repr("C")\nclass $projectedName {\n');
		var emittedUnion = false;
		for (field in fields) {
			if (field.metadata.exists("union")) {
				if (emittedUnion)
					continue;
				emittedUnion = true;
				output.add('\tpublic var ${uniqueUnionField(name, fields, fieldNames)}:$projectedName' + 'UnionData;\n');
			} else
				emitField(output, name, field, declarations, structureNames, callbackNames, fieldNames);
		}
		output.add('}\n\n');
	}

	static function emitField(output:StringBuf, owner:String, field:HxiField, declarations:Map<String, HxiDeclaration>, structureNames:Map<String, String>,
			callbackNames:Map<String, String>, fieldNames:Null<Map<String, String>>):Void {
		if (field.offset == null)
			throw 'Native record field "$owner.${field.name}" is missing its ABI offset';
		var name = projectedFieldName(owner, field.name, fieldNames),
			arrayLength:Null<Int> = null,
			type = switch field.type {
				case Array(element, length):
					arrayLength = length;
					element;
				case value: value;
			};
		output.add(arrayLength == null ? "" : '\t@:array($arrayLength)\n');
		output.add('\tpublic var $name:${renderType(type, declarations, structureNames, callbackNames, [])};\n');
	}

	static function renderType(type:HxiType, declarations:Map<String, HxiDeclaration>, structureNames:Map<String, String>, callbackNames:Map<String, String>,
			resolving:Map<String, Bool>):String {
		return switch type {
			case Const(element) | Nullable(element): renderType(element, declarations, structureNames, callbackNames, resolving);
			case Pointer(element): 'RawPtr<${renderPointee(element, declarations, structureNames, callbackNames, resolving)}>';
			case Array(_, _): throw "Nested native arrays are not supported by the Haxe native-record projection";
			case Primitive(name): primitiveType(name);
			case Named(name):
				if (resolving.exists(name))
					throw 'Cyclic HXI type alias "$name"';
				resolving.set(name, true);
				var result = switch declarations.get(name) {
					case Structure(_, _, _, _, _): structureNames.get(name);
					case Enumeration(_, representation, _, _, _) | Alias(_, representation, _):
						renderType(representation, declarations, structureNames, callbackNames, resolving);
					case Handle(_, representation, _, _): renderType(representation, declarations, structureNames, callbackNames, resolving);
					case Callback(_, _, _, _, _): 'NativeFunctionPointer<${callbackNames.get(name)}>';
					case Opaque(_, _): throw 'Opaque HXI type "$name" must be behind a pointer';
					case _: throw 'HXI declaration "$name" cannot appear in a native record field';
				};
				resolving.remove(name);
				result;
		};
	}

	static function renderPointee(type:HxiType, declarations:Map<String, HxiDeclaration>, structureNames:Map<String, String>,
			callbackNames:Map<String, String>, resolving:Map<String, Bool>):String {
		return switch type {
			case Const(element) | Nullable(element): renderPointee(element, declarations, structureNames, callbackNames, resolving);
			case Primitive("void"): "UInt8";
			case Named(name):
				switch declarations.get(name) {
					case Opaque(_, _) | Callback(_, _, _, _, _): "UInt8";
					case _: renderType(type, declarations, structureNames, callbackNames, resolving);
				};
			case _: renderType(type, declarations, structureNames, callbackNames, resolving);
		};
	}

	static function callbackSignature(parameters:Array<HxiParameter>, result:HxiType, declarations:Map<String, HxiDeclaration>,
			structureNames:Map<String, String>, callbackNames:Map<String, String>, resolving:Map<String, Bool>):String {
		var parameterTypes = [
			for (parameter in parameters)
				parameter.name + ":" + renderType(parameter.type, declarations, structureNames, callbackNames, resolving)
		];
		return "(" + parameterTypes.join(", ") + ")->" + renderType(result, declarations, structureNames, callbackNames, resolving);
	}

	static function primitiveType(name:String):String {
		return switch name {
			case "void": "Void";
			case "i8": "Int8";
			case "u8": "UInt8";
			case "i16": "Int16";
			case "u16": "UInt16";
			case "i32": "Int32";
			case "u32": "UInt32";
			case "i64": "Int64";
			case "u64": "UInt64";
			case "f32": "Float32";
			case "f64": "Float64";
			case "c_bool" | "bool32": "CBool";
			case "c_char": "CChar";
			case "c_uchar": "CUChar";
			case "c_short": "CShort";
			case "c_ushort": "CUShort";
			case "c_int": "CInt";
			case "c_uint": "CUInt";
			case "c_long": "CLong";
			case "c_ulong": "CULong";
			case "c_long_long": "CLongLong";
			case "c_ulong_long": "CULongLong";
			case "c_size": "CSize";
			case "c_wchar": "CWChar";
			case "utf8": "RawPtr<UInt8>";
			case _: throw 'Unsupported HXI primitive "$name" in a native record field';
		};
	}

	static function uniqueUnionField(owner:String, fields:Array<HxiField>, fieldNames:Null<Map<String, String>>):String {
		var candidate = "unionData", used:Map<String, Bool> = [];
		for (field in fields)
			used.set(projectedFieldName(owner, field.name, fieldNames), true);
		while (used.exists(candidate))
			candidate += "_";
		return candidate;
	}

	static function projectedFieldName(owner:String, name:String, fieldNames:Null<Map<String, String>>):String {
		var mapped = fieldNames == null ? null : fieldNames.get(owner + "." + name),
			result = mapped == null ? name : mapped;
		return switch result {
			case "super": "superType";
			case "new": "newField";
			case "this": "thisField";
			case "function": "functionField";
			case _: result;
		};
	}

	static function className(name:String, prefix:String):String {
		var result = prefix;
		for (part in name.split("_"))
			if (part.length > 0)
				result += part.substr(0, 1).toUpperCase() + part.substr(1);
		return result;
	}

	static function declarationName(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};

	static function isStructure(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Structure(_, _, _, _, _): true;
			case _: false;
		};

	static function isCallback(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Callback(_, _, _, _, _): true;
			case _: false;
		};
}
