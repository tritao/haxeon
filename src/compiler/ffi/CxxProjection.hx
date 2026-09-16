package compiler.ffi;

import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;
import compiler.ffi.HxiProjectionProfile.HxiProjectionProfile;
import compiler.ffi.HxiModel.HxiInterface;

typedef CxxProjectionSource = {
	final file:String;
	final typeName:String;
	final source:String;
}

/** Emits small Haxe object wrappers over the raw C++ HXI projection. */
class CxxProjection {
	public static function sources(model:CxxModel, hxi:HxiInterface, ?profile:HxiProjectionProfile):Array<CxxProjectionSource> {
		if (hxi.library == null)
			throw "CXX200 C++ Haxe projection requires an HXI library";
		var classNames = projectedClassNames(model),
			result:Array<CxxProjectionSource> = [];
		for (record in model.records) {
			var typeName = classNames.get(record.qualifiedName);
			result.push({
				file: typeName + ".hx",
				typeName: typeName,
				source: emit(model, hxi, record, typeName, profile)
			});
		}
		result.sort((left, right) -> Reflect.compare(left.file, right.file));
		return result;
	}

	static function emit(model:CxxModel, hxi:HxiInterface, record:CxxRecord, typeName:String, profile:Null<HxiProjectionProfile>):String {
		var abi = HxiAbi.forInterface(hxi),
			plans:Map<String, HxiFunctionAbi> = [];
		for (plan in abi.functions())
			plans.set(plan.name, plan);
		var nativeType = CxxAbiLowerer.hxiNameForQualified(record.qualifiedName),
			output = new StringBuf();
		output.add('// Generated C++ object projection for ${record.qualifiedName}. Do not edit.\n');
		output.add('import ${hxi.name};\n\n');
		output.add('class $typeName {\n');
		output.add('\tfinal __native:$nativeType;\n\n');
		output.add('\tpublic function new(native:$nativeType) {\n');
		output.add('\t\tthis.__native = native;\n');
		output.add('\t}\n\n');
		output.add('\tpublic static inline function fromNative(native:$nativeType):$typeName return new $typeName(native);\n');
		output.add('\tpublic inline function nativeHandle():$nativeType return __native;\n');

		var methods = record.methods.copy();
		methods.sort(function(left, right) {
			var result = Reflect.compare(left.name, right.name);
			return result == 0 ? Reflect.compare(left.symbol, right.symbol) : result;
		});
		var counts:Map<String, Int> = [];
		for (method in methods)
			counts.set(method.name, (counts.get(method.name) == null ? 0 : counts.get(method.name)) + 1);
		var indices:Map<String, Int> = [];
		for (method in methods) {
			var plan = method.loweredName == null ? null : plans.get(method.loweredName);
			if (plan == null)
				throw 'CXX201 missing lowered call plan for ${method.qualifiedName}';
			var index = indices.get(method.name);
			if (index == null)
				index = 0;
			indices.set(method.name, index + 1);
			var methodName = counts.get(method.name) == 1 ? method.name : method.name + "_" + index;
			validateMethodName(methodName, method);
			var argumentOffset = method.isStatic ? 0 : 1,
				arguments:Array<String> = [],
				calls:Array<String> = [];
			for (parameterIndex in 0...method.parameters.length) {
				var argument = plan.arguments[parameterIndex + argumentOffset],
					projected = HxiHaxeEmitter.project(argument, false, profile);
				if (projected == null)
					throw 'CXX201 unsupported Haxe projection for ${method.qualifiedName} parameter ${parameterIndex + 1}';
				var argumentName = identifier(method.parameters[parameterIndex].name) ? method.parameters[parameterIndex].name : 'arg$parameterIndex';
				arguments.push('$argumentName:${projected.haxeType}');
				calls.push(argumentName);
			}
			var result = HxiHaxeEmitter.project(plan.result, true, profile);
			if (result == null)
				throw 'CXX201 unsupported Haxe projection for ${method.qualifiedName} result';
			var publicFunction = HxiHaxeEmitter.projectedFunctionName(method.loweredName, profile),
				callArguments = (method.isStatic ? [] : ["__native"]).concat(calls),
				staticModifier = method.isStatic ? " static" : "";
			output.add('\tpublic$staticModifier function $methodName(${arguments.join(", ")}):${result.haxeType} {\n');
			if (result.haxeType == "Void")
				output.add('\t\t${hxi.name}.$publicFunction(${callArguments.join(", ")});\n');
			else
				output.add('\t\treturn ${hxi.name}.$publicFunction(${callArguments.join(", ")});\n');
			output.add('\t}\n');
		}
		output.add('}\n');
		return output.toString();
	}

	static function projectedClassNames(model:CxxModel):Map<String, String> {
		var counts:Map<String, Int> = [];
		for (record in model.records)
			counts.set(record.name, (counts.get(record.name) == null ? 0 : counts.get(record.name)) + 1);
		var result:Map<String, String> = [];
		for (record in model.records) {
			var typeName = counts.get(record.name) == 1 ? record.name : pascalQualifiedName(record.qualifiedName);
			validateTypeName(typeName, record);
			if (Lambda.exists([for (other in result.keys()) result.get(other)], value -> value == typeName))
				throw 'CXX202 projected class name collision for ${record.qualifiedName}: "$typeName"';
			result.set(record.qualifiedName, typeName);
		}
		return result;
	}

	static function pascalQualifiedName(value:String):String {
		var output = "";
		for (part in value.split("::"))
			if (part.length > 0)
				output += part.charAt(0).toUpperCase() + part.substr(1);
		return output;
	}

	static function validateTypeName(name:String, record:CxxRecord):Void {
		if (!identifier(name) || name == "Bool" || name == "Float" || name == "Int" || name == "String" || name == "Void")
			throw 'CXX202 invalid projected class name "$name" for ${record.qualifiedName}';
	}

	static function validateMethodName(name:String, method:CxxMethod):Void
		if (!identifier(name) || name == "fromNative" || name == "nativeHandle")
			throw 'CXX202 invalid projected method name "$name" for ${method.qualifiedName}';

	static function identifier(value:String):Bool {
		if (value == null || value.length == 0)
			return false;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index),
				letter = code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code;
			if (index == 0) {
				if (!letter && code != "_".code)
					return false;
			} else if (!letter && (code < "0".code || code > "9".code) && code != "_".code)
				return false;
		}
		return switch value {
			case "abstract" | "break" | "case" | "cast" | "catch" | "class" | "continue" | "default" | "do" | "else" | "enum" | "extends" | "extern" |
				"false" | "final" | "for" | "function" | "if" | "import" | "in" | "interface" | "macro" | "new" | "null" | "override" | "package" |
				"private" | "public" | "return" | "static" | "super" | "switch" | "this" | "throw" | "true" | "try" | "typedef" | "untyped" | "using" |
				"var" | "while": false;
			case _: true;
		};
	}
}
