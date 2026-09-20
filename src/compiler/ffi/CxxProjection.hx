package compiler.ffi;

import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxParameter;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxType;
import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;
import compiler.ffi.HxiProjectionProfile.HxiProjectionProfile;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.NativeCallPlan.NativeDispatch;

typedef CxxProjectionSource = {
	final file:String;
	final typeName:String;
	final source:String;
}

/** Emits small Haxe object wrappers over the raw C++ HXI projection. */
class CxxProjection {
	public static function sources(model:CxxModel, hxi:HxiInterface, ?profile:HxiProjectionProfile,
			?nativePlans:Array<HxiFunctionAbi>):Array<CxxProjectionSource> {
		if (hxi.library == null)
			throw "CXX200 C++ Haxe projection requires an HXI library";
		var classNames = projectedClassNames(model),
			abi = HxiAbi.forInterface(hxi),
			availablePlans = nativePlans == null ? abi.functions() : nativePlans,
			plans:Map<String, HxiFunctionAbi> = [],
			ownedRecords:Map<String, String> = [],
			result:Array<CxxProjectionSource> = [];
		for (plan in availablePlans)
			plans.set(plan.name, plan);
		for (functionModel in model.functions) {
			var plan = functionModel.loweredName == null ? null : plans.get(functionModel.loweredName);
			if (plan != null)
				switch plan.resultPolicy.ownership {
					case HxiOwnership.Owned(_) if (pointerRecord(functionModel.result) != null):
						var recordName = pointerRecord(functionModel.result),
							typeName = classNames.get(recordName);
						if (typeName == null)
							throw 'CXX205 owned C++ result ${functionModel.qualifiedName} refers to an unprojected record $recordName';
						ownedRecords.set(functionModel.qualifiedName, typeName);
					case _:
				}
		}
		for (record in model.records) {
			var typeName = classNames.get(record.qualifiedName);
			result.push({
				file: typeName + ".hx",
				typeName: typeName,
				source: emit(model, hxi, record, typeName, profile, nativePlans)
			});
			var owned = false;
			for (ownedType in ownedRecords)
				if (ownedType == typeName)
					owned = true;
			if (owned)
				result.push({
					file: "Owned" + typeName + ".hx",
					typeName: "Owned" + typeName,
					source: emitOwnedRecord(hxi, record, typeName, profile)
				});
		}
		if (Lambda.exists(model.functions, functionModel -> functionModel.thunkSymbol != null
			|| ownedRecords.exists(functionModel.qualifiedName)))
			result.push({
				file: hxi.name + "Functions.hx",
				typeName: hxi.name + "Functions",
				source: emitFunctions(model, hxi, profile, nativePlans, ownedRecords)
			});
		result.sort((left, right) -> Reflect.compare(left.file, right.file));
		return result;
	}

	static function emitOwnedRecord(hxi:HxiInterface, record:CxxRecord, typeName:String, profile:Null<HxiProjectionProfile>):String {
		var nativeType = CxxAbiLowerer.hxiNameForQualified(record.qualifiedName),
			rawOwnedType = HxiHaxeEmitter.ownedTypeName(nativeType, profile),
			ownerType = "Owned" + typeName,
			output = new StringBuf();
		output.add('// Generated owned C++ object projection for ${record.qualifiedName}. Do not edit.\n');
		output.add('import ${hxi.name};\n');
		output.add('import $typeName;\n\n');
		output.add('class $ownerType {\n');
		output.add('\tfinal __owner:$rawOwnedType;\n\n');
		output.add('\tprivate function new(owner:$rawOwnedType) this.__owner = owner;\n');
		output.add('\tpublic static function adopt(owner:$rawOwnedType):$ownerType return new $ownerType(owner);\n');
		output.add('\tpublic function borrow():$typeName { if (isClosed()) throw "C++ owned object is closed"; return $typeName.fromNative(__owner.borrow()); }\n');
		output.add('\tpublic function nativeHandle():$typeName return borrow();\n');
		output.add('\tpublic function isClosed():Bool return __owner.isClosed();\n');
		output.add('\tpublic function close():Bool return __owner.close();\n');
		output.add('}\n');
		return output.toString();
	}

	static function emit(model:CxxModel, hxi:HxiInterface, record:CxxRecord, typeName:String, profile:Null<HxiProjectionProfile>,
			nativePlans:Null<Array<HxiFunctionAbi>>):String {
		var abi = HxiAbi.forInterface(hxi),
			plans:Map<String, HxiFunctionAbi> = [],
			availablePlans = nativePlans == null ? abi.functions() : nativePlans;
		for (plan in availablePlans)
			plans.set(plan.name, plan);
		var virtualArities:Map<Int, Bool> = [];
		for (method in record.methods) {
			var plan = method.loweredName == null ? null : plans.get(method.loweredName);
			if (plan != null)
				switch plan.dispatch {
					case CxxVirtual(_, _):
						virtualArities.set(method.parameters.length, true);
					case _:
				}
		}
		var nativeType = CxxAbiLowerer.hxiNameForQualified(record.qualifiedName),
			hasThunks = Lambda.exists(record.methods, method -> method.thunkSymbol != null),
			helperName = "__CxxThunk_" + typeName,
			memoryHelper = "__CxxNativeMemory_" + typeName,
			virtualHelper = "__CxxVirtual_" + typeName,
			output = new StringBuf();
		output.add('// Generated C++ object projection for ${record.qualifiedName}. Do not edit.\n');
		output.add('import ${hxi.name};\n');
		output.add('@:noCompletion\n@:hlNative("haxeon_runtime")\nprivate class $memoryHelper {\n');
		output.add('\tpublic static function native_pointer_alloc(size:Int):hl.Abstract<"native_pointer"> return null;\n');
		output.add('\tpublic static function native_pointer_close(pointer:hl.Abstract<"native_pointer">):Bool return false;\n');
		output.add('}\n\n');
		if (hasThunks)
			emitThunkErrorHelper(output, helperName);
		if ([for (arity in virtualArities.keys()) arity].length > 0) {
			output.add('@:noCompletion\n@:hlNative("haxeon_runtime")\nprivate class $virtualHelper {\n');
			var arities = [for (arity in virtualArities.keys()) arity];
			arities.sort(Reflect.compare);
			for (arity in arities) {
				var arguments = [for (index in 0...arity) 'arg$index:Dynamic'];
				output.add('\tpublic static function native_virtual_invoke_$arity(signature:String, object:hl.Abstract<"native_pointer">, vtableIndex:Int, thisAdjustment:Int${arguments.length == 0 ? "" : ", " + arguments.join(", ")}):Dynamic return null;\n');
			}
			output.add('}\n\n');
		}
		output.add('class $typeName {\n');
		output.add('\tfinal __native:$nativeType;\n\n');
		output.add('\tfinal __owned:Bool;\n');
		output.add('\tvar __closed:Bool;\n\n');
		output.add('\tprivate function new(native:$nativeType, owned:Bool) {\n');
		output.add('\t\tthis.__native = native;\n');
		output.add('\t\tthis.__owned = owned;\n');
		output.add('\t\tthis.__closed = false;\n');
		output.add('\t}\n\n');
		output.add('\tpublic static inline function fromNative(native:$nativeType):$typeName return new $typeName(native, false);\n');
		output.add('\tpublic inline function nativeHandle():$nativeType {\n');
		output.add('\t\tif (__closed) throw "C++ object is closed";\n');
		output.add('\t\treturn __native;\n');
		output.add('\t}\n');
		output.add('\tpublic inline function isClosed():Bool return __closed;\n');

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
			if (method.isConstructor || method.isDestructor)
				continue;
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
				calls:Array<String> = [],
				setup:Array<String> = [],
				argumentCursor = argumentOffset;
			for (parameterIndex in 0...method.parameters.length) {
				argumentCursor = appendProjectedParameter(arguments, calls, setup, method.parameters[parameterIndex], plan.arguments, argumentCursor, profile,
					parameterIndex, method.qualifiedName);
			}
			if (argumentCursor != plan.arguments.length)
				throw 'CXX201 native parameter expansion mismatch for ${method.qualifiedName}';
			var result = HxiHaxeEmitter.project(plan.result, true, profile);
			if (result == null)
				throw 'CXX201 unsupported Haxe projection for ${method.qualifiedName} result';
			var publicFunction = HxiHaxeEmitter.projectedFunctionName(method.loweredName, profile),
				callArguments = (method.isStatic ? [] : ["nativeHandle()"]).concat(calls),
				staticModifier = method.isStatic ? " static" : "";
			output.add('\tpublic$staticModifier function $methodName(${arguments.join(", ")}):${result.haxeType} {\n');
			for (line in setup)
				output.add('\t\t$line\n');
			var virtual:Null<{index:Int, adjustment:Int}> = switch plan.dispatch {
				case CxxVirtual(index, adjustment): {index: index, adjustment: adjustment};
				case _: null;
			};
			if (virtual == null) {
				if (result.haxeType == "Void") {
					output.add('\t\t${hxi.name}.$publicFunction(${callArguments.join(", ")});\n');
					if (method.thunkSymbol != null)
						output.add('\t\t$helperName.throwIfFailed("${escape(hxi.library == null ? "" : hxi.library)}");\n');
				} else if (method.thunkSymbol == null)
					output.add('\t\treturn ${hxi.name}.$publicFunction(${callArguments.join(", ")});\n');
				else {
					output.add('\t\tvar __result = ${hxi.name}.$publicFunction(${callArguments.join(", ")});\n');
					output.add('\t\t$helperName.throwIfFailed("${escape(hxi.library == null ? "" : hxi.library)}");\n');
					output.add('\t\treturn __result;\n');
				}
			} else {
				var signature = HxiHaxeEmitter.nativeSignature(hxi, plan),
					virtualCall = '$virtualHelper.native_virtual_invoke_${method.parameters.length}("${escape(signature)}", cast nativeHandle(), ${virtual.index}, ${virtual.adjustment}${calls.length == 0 ? "" : ", " + calls.join(", ")})';
				if (result.haxeType == "Void")
					output.add('\t\t$virtualCall;\n');
				else
					output.add('\t\treturn cast $virtualCall;\n');
			}
			output.add('\t}\n');
		}

		var constructors = [for (method in methods) if (method.isConstructor) method],
			destructors = [for (method in methods) if (method.isDestructor) method];
		if (constructors.length != 0 && destructors.length == 0)
			throw 'CXX203 lifetime projection for ${record.qualifiedName} requires an explicit destructor';
		if (destructors.length != 0) {
			var destructor = destructors[0],
				destructorPlan = destructor.loweredName == null ? null : plans.get(destructor.loweredName);
			if (destructorPlan == null)
				throw 'CXX201 missing lowered destructor call plan for ${destructor.qualifiedName}';
			switch destructorPlan.dispatch {
				case CxxDestructor:
				case _:
					throw 'CXX204 destructor ${destructor.qualifiedName} has an invalid native dispatch plan';
			}
			var destructorFunction = HxiHaxeEmitter.projectedFunctionName(destructor.loweredName, profile);
			output.add('\tpublic function close():Void {\n');
			output.add('\t\tif (!__owned) throw "Cannot close a borrowed C++ object";\n');
			output.add('\t\tif (!__closed) {\n');
			output.add('\t\t\t${hxi.name}.$destructorFunction(__native);\n');
			output.add('\t\t\t$memoryHelper.native_pointer_close(cast __native);\n');
			output.add('\t\t\t__closed = true;\n');
			output.add('\t\t}\n');
			output.add('\t}\n');
		}
		for (index in 0...constructors.length) {
			var constructor = constructors[index],
				constructorPlan = constructor.loweredName == null ? null : plans.get(constructor.loweredName);
			if (constructorPlan == null)
				throw 'CXX201 missing lowered constructor call plan for ${constructor.qualifiedName}';
			switch constructorPlan.dispatch {
				case CxxConstructor:
				case _:
					throw 'CXX204 constructor ${constructor.qualifiedName} has an invalid native dispatch plan';
			}
			var constructorArguments:Array<String> = [],
				constructorCalls:Array<String> = [];
			for (parameterIndex in 0...constructor.parameters.length) {
				var argument = constructorPlan.arguments[parameterIndex + 1],
					projected = HxiHaxeEmitter.project(argument, false, profile);
				if (projected == null)
					throw 'CXX201 unsupported Haxe projection for ${constructor.qualifiedName} parameter ${parameterIndex + 1}';
				var argumentName = identifier(constructor.parameters[parameterIndex].name) ? constructor.parameters[parameterIndex].name : 'arg$parameterIndex';
				constructorArguments.push('$argumentName:${projected.haxeType}');
				constructorCalls.push(argumentName);
			}
			var constructorName = constructors.length == 1 ? "create" : "create_" + index,
				constructorFunction = HxiHaxeEmitter.projectedFunctionName(constructor.loweredName, profile);
			output.add('\tpublic static function $constructorName(${constructorArguments.join(", ")}):$typeName {\n');
			output.add('\t\tvar native:$nativeType = cast $memoryHelper.native_pointer_alloc(${record.size});\n');
			output.add('\t\tvar result = new $typeName(native, true);\n');
			output.add('\t\t${hxi.name}.$constructorFunction(native${constructorCalls.length == 0 ? "" : ", " + constructorCalls.join(", ")});\n');
			output.add('\t\treturn result;\n');
			output.add('\t}\n');
		}
		output.add('}\n');
		return output.toString();
	}

	static function emitFunctions(model:CxxModel, hxi:HxiInterface, profile:Null<HxiProjectionProfile>, nativePlans:Null<Array<HxiFunctionAbi>>,
			ownedRecords:Map<String, String>):String {
		var abi = HxiAbi.forInterface(hxi),
			plans:Map<String, HxiFunctionAbi> = [],
			availablePlans = nativePlans == null ? abi.functions() : nativePlans,
			output = new StringBuf();
		for (plan in availablePlans)
			plans.set(plan.name, plan);
		output.add('// Generated C++ free-function projection for ${hxi.name}. Do not edit.\n');
		output.add('import ${hxi.name};\n');
		var helperName = "__CxxThunk_" + hxi.name + "Functions";
		var hasThunk = Lambda.exists(model.functions, functionModel -> functionModel.thunkSymbol != null);
		if (hasThunk)
			emitThunkErrorHelper(output, helperName);
		output.add('class ${hxi.name}Functions {\n');
		var functions = model.functions.copy();
		functions.sort((left, right) -> {
			var result = Reflect.compare(left.name, right.name);
			return result == 0 ? Reflect.compare(left.symbol, right.symbol) : result;
		});
		var counts:Map<String, Int> = [], indices:Map<String, Int> = [];
		for (functionModel in functions)
			if (functionModel.thunkSymbol != null || ownedRecords.exists(functionModel.qualifiedName))
				counts.set(functionModel.name, (counts.get(functionModel.name) == null ? 0 : counts.get(functionModel.name)) + 1);
		for (functionModel in functions) {
			if (functionModel.thunkSymbol == null && !ownedRecords.exists(functionModel.qualifiedName))
				continue;
			var plan = functionModel.loweredName == null ? null : plans.get(functionModel.loweredName);
			if (plan == null)
				throw 'CXX201 missing lowered call plan for ${functionModel.qualifiedName}';
			var index = indices.get(functionModel.name);
			if (index == null)
				index = 0;
			indices.set(functionModel.name, index + 1);
			var functionName = counts.get(functionModel.name) == 1 ? functionModel.name : functionModel.name + "_" + index;
			validateFunctionName(functionName, functionModel);
			var arguments:Array<String> = [],
				calls:Array<String> = [],
				setup:Array<String> = [],
				argumentCursor = 0;
			for (parameterIndex in 0...functionModel.parameters.length) {
				argumentCursor = appendProjectedParameter(arguments, calls, setup, functionModel.parameters[parameterIndex], plan.arguments, argumentCursor,
					profile, parameterIndex, functionModel.qualifiedName);
			}
			if (argumentCursor != plan.arguments.length)
				throw 'CXX201 native parameter expansion mismatch for ${functionModel.qualifiedName}';
			var ownedRecordType = ownedRecords.get(functionModel.qualifiedName),
				result = ownedRecordType == null ? HxiHaxeEmitter.project(plan.result, true, profile) : null,
				resultType = ownedRecordType == null ? result == null ? null : result.haxeType : "Owned" + ownedRecordType;
			if (resultType == null)
				throw 'CXX201 unsupported Haxe projection for ${functionModel.qualifiedName} result';
			var nativeName = HxiHaxeEmitter.projectedFunctionName(functionModel.loweredName, profile);
			output.add('\tpublic static function $functionName(${arguments.join(", ")}):$resultType {\n');
			for (line in setup)
				output.add('\t\t$line\n');
			if (ownedRecordType != null) {
				output.add('\t\tvar __owner = ${hxi.name}.$nativeName(${calls.join(", ")});\n');
				if (functionModel.thunkSymbol != null)
					output.add('\t\t$helperName.throwIfFailed("${escape(hxi.library == null ? "" : hxi.library)}");\n');
				output.add('\t\treturn Owned$ownedRecordType.adopt(__owner);\n');
			} else if (resultType == "Void") {
				output.add('\t\t${hxi.name}.$nativeName(${calls.join(", ")});\n');
				if (functionModel.thunkSymbol != null)
					output.add('\t\t$helperName.throwIfFailed("${escape(hxi.library == null ? "" : hxi.library)}");\n');
			} else {
				output.add('\t\tvar __result = ${hxi.name}.$nativeName(${calls.join(", ")});\n');
				if (functionModel.thunkSymbol != null)
					output.add('\t\t$helperName.throwIfFailed("${escape(hxi.library == null ? "" : hxi.library)}");\n');
				output.add('\t\treturn __result;\n');
			}
			output.add('\t}\n');
		}
		output.add('}\n');
		return output.toString();
	}

	static function pointerRecord(type:CxxType):Null<String>
		return switch type {
			case CxxType.CxxPointer(element): namedRecord(element);
			case CxxType.CxxConst(element): pointerRecord(element);
			case _: null;
		};

	static function namedRecord(type:CxxType):Null<String>
		return switch type {
			case CxxType.CxxNamed(name): name;
			case CxxType.CxxConst(element): namedRecord(element);
			case _: null;
		};

	static function appendProjectedParameter(arguments:Array<String>, calls:Array<String>, setup:Array<String>, parameter:CxxParameter,
			nativeArguments:Array<HxiAbiValue>, cursor:Int, profile:Null<HxiProjectionProfile>, index:Int, owner:String):Int {
		var argumentName = identifier(parameter.name) ? parameter.name : 'arg$index';
		if (CxxTypeTools.isStringView(parameter.type)) {
			var stringValue = HxiHaxeEmitter.project(nativeArguments[cursor], false, profile),
				lengthValue = HxiHaxeEmitter.project(nativeArguments[cursor + 1], false, profile);
			if (stringValue == null || stringValue.haxeType != "String" || lengthValue == null || lengthValue.haxeType != "Int"
				&& lengthValue.haxeType != "haxe.Int64")
				throw 'CXX201 unsupported Haxe std::string_view projection for $owner parameter ${index + 1}';
			arguments.push('$argumentName:String');
			var bytesName = '__cxx_${argumentName}_bytes_$index';
			setup.push('var $bytesName = haxe.io.Bytes.ofString($argumentName);');
			calls.push(argumentName);
			calls.push(lengthValue.haxeType == "haxe.Int64" ? 'haxe.Int64.ofInt($bytesName.length)' : '$bytesName.length');
			return cursor + 2;
		}
		if (CxxTypeTools.isByteSpan(parameter.type)) {
			var spanValue = HxiHaxeEmitter.project(nativeArguments[cursor], false, profile),
				lengthValue = HxiHaxeEmitter.project(nativeArguments[cursor + 1], false, profile);
			if (spanValue == null
				|| spanValue.haxeType != "haxe.io.Bytes"
				|| lengthValue == null
				|| lengthValue.haxeType != "Int"
				&& lengthValue.haxeType != "haxe.Int64")
				throw 'CXX201 unsupported Haxe std::span projection for $owner parameter ${index + 1}';
			arguments.push('$argumentName:haxe.io.Bytes');
			calls.push(argumentName);
			calls.push(lengthValue.haxeType == "haxe.Int64" ? 'haxe.Int64.ofInt($argumentName.length)' : '$argumentName.length');
			return cursor + 2;
		}
		var projected = HxiHaxeEmitter.project(nativeArguments[cursor], false, profile);
		if (projected == null)
			throw 'CXX201 unsupported Haxe projection for $owner parameter ${index + 1}';
		arguments.push('$argumentName:${projected.haxeType}');
		calls.push(argumentName);
		return cursor + 1;
	}

	static function emitThunkErrorHelper(output:StringBuf, helperName:String):Void {
		var nativeHelperName = helperName + "Native";
		output.add('@:noCompletion\n@:hlNative("haxeon_runtime")\nprivate class $nativeHelperName {\n');
		output.add('\tpublic static function native_cxx_last_error(library:String):Null<String> return null;\n');
		output.add('}\n\n');
		output.add('@:noCompletion\nprivate class $helperName {\n');
		output.add('\tpublic static function throwIfFailed(library:String):Void {\n');
		output.add('\t\tvar error = $nativeHelperName.native_cxx_last_error(library);\n');
		output.add('\t\tif (error != null && error.length > 0) throw "C++ exception: " + error;\n');
		output.add('\t}\n');
		output.add('}\n\n');
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
		if (!identifier(name) || name == "fromNative" || name == "nativeHandle" || name == "isClosed" || name == "close")
			throw 'CXX202 invalid projected method name "$name" for ${method.qualifiedName}';

	static function validateFunctionName(name:String, functionModel:CxxFunction):Void
		if (!identifier(name))
			throw 'CXX202 invalid projected function name "$name" for ${functionModel.qualifiedName}';

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

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');
}
