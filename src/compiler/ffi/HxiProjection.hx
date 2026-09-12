package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrType;
import compiler.ffi.HxiModel.HxiPointerOwnership;

/** Projects bridgeable HXI functions into a synthetic, source-visible module. */
class HxiProjection {
	/** Validate Haxe naming rules against the declarations the profile can project. */
	public static function validateProfile(path:String, model:HxiInterface, ?omitted:Map<String, Bool>,
			?visibleDeclarations:Map<String, HxiDeclaration>, profile:HxiProjectionProfile):Void {
		if (profile.interfaceName != model.name)
			profileError(path, 'names interface "${profile.interfaceName}" but was applied to "${model.name}"');

		var declarations:Map<String, HxiDeclaration> = [],
			local:Map<String, HxiDeclaration> = [];
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations) {
			var name = declarationName(declaration);
			declarations.set(name, declaration);
			local.set(name, declaration);
		}

		for (name in sortedKeys(profile.typeNames)) {
			var declaration = declarations.get(name), entry = 'typeNames.$name';
			if (declaration == null)
				profileError(path, '$entry references unknown HXI type "$name"');
			if (!isProjectedType(declaration))
				profileError(path, '$entry refers to "$name", which has no generated Haxe type');
			validateTypePath(path, entry, profile.typeNames.get(name), local.exists(name) && !isOmitted(omitted, name));
		}
		for (name in sortedKeys(profile.enumNames)) {
			var declaration = declarations.get(name), entry = 'enumNames.$name';
			if (declaration == null)
				profileError(path, '$entry references unknown HXI enum "$name"');
			if (!isEnumeration(declaration))
				profileError(path, '$entry refers to "$name", which is not an enum');
			validateTypePath(path, entry, profile.enumNames.get(name), local.exists(name) && !isOmitted(omitted, name));
			var typeName = profile.typeNames.get(name);
			if (typeName != null && typeName != profile.enumNames.get(name))
				profileError(path, '$entry conflicts with typeNames.$name');
		}
		for (enumName in sortedKeys(profile.enumValueNames)) {
			var declaration = declarations.get(enumName), entry = 'enumValueNames.$enumName';
			if (declaration == null)
				profileError(path, '$entry references unknown HXI enum "$enumName"');
			var values = switch declaration {
				case Enumeration(_, _, _, values, _): values;
				case _: profileError(path, '$entry refers to "$enumName", which is not an enum'); [];
			};
			if (!local.exists(enumName) || isOmitted(omitted, enumName))
				profileError(path, '$entry refers to an enum projected by a dependency; rename its values in that interface profile');
			var valueNames:Map<String, Bool> = [for (value in values) value.name => true];
			for (valueName in sortedKeys(profile.enumValueNames.get(enumName))) {
				if (!valueNames.exists(valueName))
					profileError(path, '$entry.$valueName references an unknown enum value');
				validateIdentifier(path, '$entry.$valueName', profile.enumValueNames.get(enumName).get(valueName));
			}
		}
		for (name in sortedKeys(profile.functionNames)) {
			var declaration = local.get(name), entry = 'functionNames.$name';
			if (declaration == null)
				profileError(path, '$entry references an unknown function in this interface');
			if (!isFunction(declaration) || isOmitted(omitted, name))
				profileError(path, '$entry does not refer to a function projected by this interface');
			validateIdentifier(path, entry, profile.functionNames.get(name));
		}
		for (key in sortedKeys(profile.fieldNames)) {
			var separator = key.indexOf("."),
				typeName = separator < 0 ? "" : key.substr(0, separator),
				fieldName = separator < 0 ? "" : key.substr(separator + 1),
				entry = 'fieldNames.$typeName.$fieldName',
				declaration = local.get(typeName);
			if (separator <= 0 || separator == key.length - 1)
				profileError(path, 'fieldNames key "$key" must have the form "type.field"');
			var fields = switch declaration {
				case Structure(_, _, _, fields, _) if (!isOmitted(omitted, typeName)): fields;
				case null: profileError(path, '$entry references an unknown structure in this interface'); [];
				case _: profileError(path, '$entry does not refer to a structure projected by this interface'); [];
			};
			if (!Lambda.exists(fields, field -> field.name == fieldName))
				profileError(path, '$entry references an unknown structure field');
			validateIdentifier(path, entry, profile.fieldNames.get(key));
		}
		for (name in sortedKeys(profile.constantNames)) {
			var declaration = local.get(name), entry = 'constantNames.$name';
			if (declaration == null)
				profileError(path, '$entry references an unknown constant in this interface');
			if (!isConstant(declaration) || isOmitted(omitted, name))
				profileError(path, '$entry does not refer to a constant projected by this interface');
			validateIdentifier(path, entry, profile.constantNames.get(name));
		}

		var moduleNames:Map<String, String> = [],
			constantMembers:Map<String, String> = [],
			hasCallbacks = false,
			hasOpaqueTypes = false,
			hasConstants = false;
		for (declaration in model.declarations)
			if (!isOmitted(omitted, declarationName(declaration)))
				switch declaration {
					case Callback(_, _, _, _, _): hasCallbacks = true;
					case Opaque(_, _): hasOpaqueTypes = true;
					case Constant(_, _, _): hasConstants = true;
					case _:
				}
		if (hasCallbacks)
			addProjectedName(path, "module", "HxiCallbackError", "generated callback error type", moduleNames);
		if (hasOpaqueTypes) {
			addProjectedName(path, "module", '__hxi_${model.name}_native_pointer_close', "opaque handle close helper", moduleNames);
			addProjectedName(path, "module", '__hxi_${model.name}_native_pointer_is_closed', "opaque handle state helper", moduleNames);
		}
		if (hasConstants)
			addProjectedName(path, "module", upperFirst(model.name) + "Constants", "generated constants type", moduleNames);

		for (declaration in model.declarations) {
			var declarationName = declarationName(declaration);
			if (isOmitted(omitted, declarationName))
				continue;
			switch declaration {
				case Callback(name, _, _, _, _):
					var projected = projectedTypeName(name, profile);
					addProjectedName(path, "module", projected, 'callback "$name"', moduleNames);
					addProjectedName(path, "module", projected + "Callback", 'callback wrapper for "$name"', moduleNames);
				case Enumeration(name, _, _, values, _):
					addProjectedName(path, "module", enumTypeName(name, profile), 'enum "$name"', moduleNames);
					var members:Map<String, String> = [], prefix = enumValuePrefix(values, profile);
					for (value in values)
						addProjectedName(path, 'enum "$name"', enumValueName(value.name, prefix, name, profile),
							'enum value "$name.${value.name}"', members);
				case Opaque(name, _):
					addProjectedName(path, "module", projectedTypeName(name, profile), 'opaque type "$name"', moduleNames);
					addProjectedName(path, "module", ownedTypeName(name, profile), 'owned opaque type "$name"', moduleNames);
				case Handle(name, _, _) | Structure(name, _, _, _, _):
					addProjectedName(path, "module", projectedTypeName(name, profile), 'type "$name"', moduleNames);
					var fields = switch declaration {
						case Structure(_, _, _, fields, _): fields;
						case _: [];
					};
					var members:Map<String, String> = [];
					for (field in fields)
						addProjectedName(path, 'structure "$name"', projectedFieldName(name, field.name, profile),
							'structure field "$name.${field.name}"', members);
				case Function(name, parameters, result, _, _, _, _, _):
					var publicName = projectedFunctionName(name, profile);
					addProjectedName(path, "module", publicName, 'function "$name"', moduleNames);
					if (hasOutput(parameters))
						addProjectedName(path, "module", '__hxi_raw_$name', 'raw wrapper for "$name"', moduleNames);
					if (hasGeneratedOutputResult(parameters, result))
						addProjectedName(path, "module", upperFirst(publicName) + "OutResult", 'output result type for "$name"', moduleNames);
					if (byteArrayParameter(parameters) != null)
						addProjectedName(path, "module", publicName + "_slice", 'byte-slice wrapper for "$name"', moduleNames);
				case Constant(name, _, _):
					addProjectedName(path, "constants", projectedConstantName(name, profile), 'constant "$name"', constantMembers);
				case _:
			}
		}
	}

	static function declarationName(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};

	static function sortedKeys<T>(values:Map<String, T>):Array<String> {
		var result = [for (name in values.keys()) name];
		result.sort(Reflect.compare);
		return result;
	}

	static function isProjectedType(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Opaque(_, _) | Handle(_, _, _) | Structure(_, _, _, _, _) | Enumeration(_, _, _, _, _) | Callback(_, _, _, _, _): true;
			case _: false;
		};

	static function isEnumeration(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Enumeration(_, _, _, _, _): true;
			case _: false;
		};

	static function isFunction(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Function(_, _, _, _, _, _, _, _): true;
			case _: false;
		};

	static function isConstant(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Constant(_, _, _): true;
			case _: false;
		};

	static function validateTypePath(path:String, entry:String, projected:String, isLocal:Bool):Void {
		var parts = projected == null ? [] : projected.split(".");
		if (parts.length == 0 || (isLocal && parts.length != 1))
			profileError(path, '$entry must be an unqualified type name for a declaration emitted by this interface');
		for (part in parts)
			if (!isHaxeIdentifier(part))
				profileError(path, '$entry projects to invalid Haxe type name "$projected"');
	}

	static function validateIdentifier(path:String, entry:String, projected:String):Void
		if (!isHaxeIdentifier(projected))
			profileError(path, '$entry projects to invalid Haxe identifier "$projected"');

	static function isHaxeIdentifier(value:String):Bool {
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
		return !isHaxeKeyword(value);
	}

	static function isHaxeKeyword(value:String):Bool
		return switch value {
			case "abstract" | "break" | "case" | "cast" | "catch" | "class" | "continue" | "default" | "do" | "dynamic" | "else" | "enum" |
				"extends" | "extern" | "false" | "final" | "for" | "from" | "function" | "if" | "implements" | "import" | "in" | "inline" |
				"interface" | "macro" | "new" | "null" | "operator" | "overload" | "override" | "package" | "private" | "public" | "return" |
				"static" | "super" | "switch" | "this" | "throw" | "to" | "true" | "try" | "typedef" | "untyped" | "using" | "var" | "while" |
				"Bool" | "Float" | "Int" | "String" | "Void": true;
			case _: false;
		};

	static function addProjectedName(path:String, scope:String, projected:String, origin:String, names:Map<String, String>):Void {
		validateIdentifier(path, '$scope.$origin', projected);
		var previous = names.get(projected);
		if (previous != null)
			profileError(path, '$scope collision: $origin and $previous both project to "$projected"');
		names.set(projected, origin);
	}

	static function profileError(path:String, message:String):Void
		throw 'Invalid Haxe projection profile "$path": $message';

	public static function cNatives(model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>, ?providedAbi:HxiAbi,
			?profile:HxiProjectionProfile):Array<IrCNative> {
		var library = model.library;
		if (library == null)
			return [];
		if (profile == null)
			profile = HxiProjectionProfile.empty();
		var result:Array<IrCNative> = [],
			declarations:Map<String, HxiDeclaration> = [],
			directed:Map<String, Bool> = [],
			aggregateDescriptors:Map<String, String> = [];
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations)
			switch declaration {
				case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _) | Structure(name, _, _, _, _) | Enumeration(name, _, _, _, _) |
					Callback(name, _, _, _, _):
					declarations.set(name, declaration);
				case Function(name, parameters, _, _, _, _, _, _):
					directed.set(name, hasOutput(parameters));
				case _:
			}
		var abi = providedAbi == null ? HxiAbi.forInterface(model, declarations) : providedAbi;
		for (fn in abi.functions()) {
			if (isOmitted(omitted, fn.name))
				continue;
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
				codes.push(abiDescriptor(argument, declarations, abi, aggregateDescriptors));
			}
			var returnValue = project(fn.result, true);
			var managedBytes = fn.resultPolicy.length != null;
			var ownership:{kind:String, release:Null<String>} = switch fn.resultPolicy.ownership {
				case Unspecified: {kind: "unspecified", release: null};
				case Borrowed: {kind: "borrowed", release: null};
				case Owned(release): {kind: "owned", release: release};
			};
			if (supported && returnValue != null)
				result.push({
					name: model.name + "." + (directed.get(fn.name) == true ? "__hxi_raw_" + fn.name : projectedFunctionName(fn.name, profile)),
					library: library,
					symbol: fn.symbol,
					signature: callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi, aggregateDescriptors), fn.callConvention),
					arguments: arguments,
					result: managedBytes ? ManagedBytes : irType(returnValue.code, true),
					pointerOwnership: ownership.kind,
					pointerRelease: ownership.release,
					pointerLength: fn.resultPolicy.length,
					pointerNullable: returnValue.nullable
				});
		}
		return result;
	}

	public static function source(model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>, ?providedAbi:HxiAbi,
			?profile:HxiProjectionProfile):String {
		var library = model.library;
		if (library == null)
			return "";
		if (profile == null)
			profile = HxiProjectionProfile.empty();
		var pointerCloseHelper = '__hxi_${model.name}_native_pointer_close',
			pointerIsClosedHelper = '__hxi_${model.name}_native_pointer_is_closed',
			abi = providedAbi == null ? HxiAbi.forInterface(model, visibleDeclarations) : providedAbi,
			output = new StringBuf(),
			aggregateDescriptors:Map<String, String> = [];
		var structAccesses:Map<String, {type:String, setterType:String}> = [],
			declarations:Map<String, HxiDeclaration> = [],
			opaqueDeclarations:Array<HxiDeclaration> = [],
			functions:Map<String, HxiDeclaration> = [],
			constants:Array<{name:String, value:String}> = [],
			callbackDeclarations:Array<HxiDeclaration> = [],
			enumDeclarations:Array<HxiDeclaration> = [],
			handleDeclarations:Array<HxiDeclaration> = [],
			structureDeclarations:Array<HxiDeclaration> = [],
			functionDeclarations:Array<HxiDeclaration> = [];
		var usesNestedStructures = false,
			usesPointerFields = false,
			usesUtf8Fields = false,
			usesBorrowedBuffers = false,
			hasCallbacks = false;
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations) {
			switch declaration {
				case Opaque(name, _):
					declarations.set(name, declaration);
					if (!isOmitted(omitted, name))
						opaqueDeclarations.push(declaration);
				case Alias(name, _, _):
					declarations.set(name, declaration);
				case Function(name, _, _, _, _, _, _, _):
					functions.set(name, declaration);
					if (!isOmitted(omitted, name))
						functionDeclarations.push(declaration);
				case Callback(name, _, _, _, _):
					declarations.set(name, declaration);
					if (!isOmitted(omitted, name)) {
						callbackDeclarations.push(declaration);
						hasCallbacks = true;
					}
				case Constant(name, value, _):
					if (!isOmitted(omitted, name))
						constants.push({name: name, value: value});
				case Enumeration(name, _, _, values, _):
					declarations.set(name, declaration);
					if (!isOmitted(omitted, name))
						enumDeclarations.push(declaration);
				case Handle(name, _, _):
					declarations.set(name, declaration);
					if (!isOmitted(omitted, name))
						handleDeclarations.push(declaration);
				case Structure(name, _, _, _, _):
					declarations.set(name, declaration);
					if (!isOmitted(omitted, name))
						structureDeclarations.push(declaration);
				case _:
			}
		}
		output.add('// Generated semantic projection of ${model.name}. Do not edit.\n');
		if (constants.length != 0) {
			output.add('class ${upperFirst(model.name)}Constants {\n');
			for (constant in constants) {
				emitDocumentation(output, model, constant.name, "\t");
				output.add('\tpublic static inline final ${projectedConstantName(constant.name, profile)}:Int = ${constant.value};\n');
			}
			output.add('}\n');
		}
		if (hasCallbacks)
			output.add('enum abstract HxiCallbackError(Int) from Int to Int { var None = 0; var Exception = 1; var WrongThread = 2; var PointerContract = 3; var AggregateContract = 4; var StringContract = 5; }\n');
		for (declaration in opaqueDeclarations)
			switch declaration {
				case Opaque(name, _):
					var projectedName = projectedTypeName(name, profile);
					emitDocumentation(output, model, name);
					output.add('abstract $projectedName(hl.Abstract<"native_pointer">) {\n');
					output.add('\tpublic inline function isClosed():Bool return ${model.name}.$pointerIsClosedHelper(cast this);\n');
					output.add('}\n');
					var ownedName = ownedTypeName(name, profile);
					output.add('abstract $ownedName(hl.Abstract<"native_pointer">) {\n');
					output.add('\tpublic inline function borrow():$projectedName return cast this;\n');
					output.add('\tpublic inline function close():Bool return ${model.name}.$pointerCloseHelper(cast this);\n');
					output.add('\tpublic inline function isClosed():Bool return ${model.name}.$pointerIsClosedHelper(cast this);\n');
					output.add('}\n');
				case _:
			}
		if (opaqueDeclarations.length != 0) {
			output.add('@:hlNative("haxeon_runtime", "native_pointer_close") extern function $pointerCloseHelper(pointer:hl.Abstract<"native_pointer">):Bool;\n');
			output.add('@:hlNative("haxeon_runtime", "native_pointer_is_closed") extern function $pointerIsClosedHelper(pointer:hl.Abstract<"native_pointer">):Bool;\n');
		}
		for (callbackDeclaration in callbackDeclarations)
			switch callbackDeclaration {
				case Callback(name, parameters, result, callConvention, _):
					var projectedName = projectedTypeName(name, profile);
					var argumentTypes = [], codes = [], pointerSizes = [], pointerNullable = [], supported = true;
					for (parameter in parameters) {
						var classified = abi.classify(parameter.type),
							value = callbackProject(classified, profile);
						if (value == null) {
							supported = false;
							break;
						}
						argumentTypes.push('${parameter.name}:${value.haxeType}');
						codes.push(abiDescriptor(classified, declarations, abi, aggregateDescriptors));
						switch classified {
							case PointerValue(_, nullable, _, structure):
								var structureDeclaration = structure == null ? null : declarations.get(structure),
									size = switch structureDeclaration {
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
					var classifiedResult = abi.classify(result, true),
						returnValue = project(classifiedResult, true, profile);
					if (!supported || returnValue == null)
						continue;
					var signature = callSignature(codes.join(",") + ">" + abiDescriptor(classifiedResult, declarations, abi, aggregateDescriptors),
						callConvention);
					emitDocumentation(output, model, name);
					output.add('typedef $projectedName = (${argumentTypes.join(", ")})->${returnValue.haxeType};\n');
					output.add('abstract ${projectedName}Callback(hl.Abstract<"native_callback">) {\n');
					output.add('\tpublic inline function new(callback:$projectedName) this = ${model.name}.__hxi_callback_create(haxe.io.Bytes.ofString("$signature"), haxe.io.Bytes.ofString("${pointerSizes.join(",")}"), haxe.io.Bytes.ofString("${pointerNullable.join(",")}"), callback);\n');
					output.add('\tpublic inline function close():Bool return ${model.name}.__hxi_callback_close_$name(this);\n');
					output.add('\tpublic inline function errorKind():HxiCallbackError return ${model.name}.__hxi_callback_error_kind_$name(this);\n');
					output.add('\tpublic inline function takeError():Null<haxe.io.Bytes> return ${model.name}.__hxi_callback_take_error_$name(this);\n');
					output.add('}\n');
					output.add('@:hlNative("haxeon_runtime", "native_callback_close") extern function __hxi_callback_close_$name(callback:${projectedName}Callback):Bool;\n');
					output.add('@:hlNative("haxeon_runtime", "native_callback_error_kind") extern function __hxi_callback_error_kind_$name(callback:${projectedName}Callback):Int;\n');
					output.add('@:hlNative("haxeon_runtime", "native_callback_take_error") extern function __hxi_callback_take_error_$name(callback:${projectedName}Callback):Null<haxe.io.Bytes>;\n');
				case _:
			}
		for (declaration in enumDeclarations)
			switch declaration {
				case Enumeration(name, representation, flags, values, _):
					var underlying = project(abi.classify(representation), false, profile);
					if (underlying == null)
						continue;
					var projectedName = enumTypeName(name, profile),
						valuePrefix = enumValuePrefix(values, profile),
						bits = switch abi.classify(representation) {
							case IntegerValue(valueBits, _): valueBits;
							case _: 0;
						};
					emitDocumentation(output, model, name);
					if (flags && bits == 64) {
						output.add('abstract $projectedName(haxe.Int64) from haxe.Int64 to haxe.Int64 {\n');
						for (value in values) {
							emitDocumentation(output, model, '$name.${value.name}', "\t");
							var projectedValue = enumValueName(value.name, valuePrefix, name, profile),
								methodName = lowerFirst(projectedValue),
								low = haxe.Int64.and(value.value, haxe.Int64.parseString("4294967295")),
								high = haxe.Int64.ushr(value.value, 32),
								highLiteral = int64PartAsInt(high),
								lowLiteral = int64PartAsInt(low);
							output.add('\tpublic static inline function $methodName():$projectedName return cast haxe.Int64.make($highLiteral, $lowLiteral);\n');
						}
						output.add('\tpublic inline function contains(flag:$projectedName):Bool return haxe.Int64.compare(haxe.Int64.and(this, flag), flag) == 0;\n');
						output.add('\tpublic inline function with(flag:$projectedName):$projectedName return cast haxe.Int64.or(this, flag);\n');
						output.add('\tpublic inline function without(flag:$projectedName):$projectedName return cast haxe.Int64.and(this, haxe.Int64.xor(flag, -1));\n');
						output.add('\tpublic inline function rawValue():haxe.Int64 return this;\n');
						output.add('}\n');
					} else {
						output.add('enum abstract $projectedName(${underlying.haxeType}) from ${underlying.haxeType} to ${underlying.haxeType} {\n');
						for (value in values) {
							emitDocumentation(output, model, '$name.${value.name}', "\t");
							var projectedValue = enumValueName(value.name, valuePrefix, name, profile),
								literalValue = flags
									&& bits == 32
									&& haxe.Int64.compare(value.value,
										haxe.Int64.parseString("2147483647")) > 0 ? haxe.Int64.sub(value.value,
										haxe.Int64.parseString("4294967296")) : value.value,
								literal = haxe.Int64.toStr(literalValue);
							output.add('\tvar $projectedValue = $literal;\n');
						}
						output.add('}\n');
					}
				case _:
			}
		for (declaration in handleDeclarations)
			switch declaration {
				case Handle(name, _, _):
					var projectedName = projectedTypeName(name, profile);
					emitDocumentation(output, model, name);
					output.add('abstract $projectedName(Int) from Int to Int {\n');
					output.add('\tpublic inline function new(value:Int = 0) this = value;\n');
					output.add('\tpublic static inline function invalid():$projectedName return new $projectedName();\n');
					output.add('\tpublic inline function isValid():Bool return this != 0;\n');
					output.add('\tpublic inline function rawValue():Int return this;\n');
					output.add('}\n');
				case _:
			}
		for (declaration in structureDeclarations)
			switch declaration {
				case Structure(name, size, _, fields, _):
					var projectedName = projectedTypeName(name, profile);
					emitDocumentation(output, model, name);
					output.add('/** Managed storage; this struct value may be retained and reused across native calls. Native pointers derived from it are call-scoped. */\n');
					output.add('abstract $projectedName(haxe.io.Bytes) from haxe.io.Bytes to haxe.io.Bytes {\n');
					output.add('\tpublic static inline function size():Int return $size;\n');
					output.add('\tpublic static function array(values:Array<$projectedName>):$projectedName { var bytes = ${model.name}.__hxi_struct_alloc(values.length * $size); for (index in 0...values.length) ${model.name}.__hxi_struct_copy(bytes, index * $size, values[index], $size); return cast bytes; }\n');
					usesNestedStructures = true;
					output.add('\tpublic inline function new() this = haxe.io.Bytes.alloc($size);\n');
					for (field in fields) {
						var fieldName = projectedFieldName(name, field.name, profile);
						if (field.lengthField != null) {
							var pointed = structurePointerType(field.type, declarations, profile);
							if (pointed != null) {
								usesPointerFields = true;
								emitDocumentation(output, model, '$name.${field.name}', "\t");
								output.add('\tpublic inline function set_$fieldName(value:$pointed):Void ${model.name}.__hxi_struct_set_borrowed_bytes(this, ${field.offset}, value);\n');
								continue;
							}
							var lengthField = Lambda.find(fields, candidate -> candidate.name == field.lengthField);
							if (lengthField == null)
								throw 'Missing length field "${field.lengthField}"';
							var lengthValue = abi.classify(lengthField.type),
								lengthBytes = switch lengthValue {
									case IntegerValue(bits, _): Std.int(bits / 8);
									case _: throw 'Invalid length field "${lengthField.name}"';
								};
							usesBorrowedBuffers = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_${fieldName}_bytes():haxe.io.Bytes return ${model.name}.__hxi_struct_copy_pointer(this, ${field.offset}, ${lengthField.offset}, $lengthBytes);\n');
							continue;
						}
						var array = arrayType(field.type, declarations);
						if (array != null) {
							var nestedElement = structureType(array.element, declarations, profile);
							if (nestedElement != null) {
								usesNestedStructures = true;
								emitDocumentation(output, model, '$name.${field.name}', "\t");
								output.add('\tpublic inline function get_${fieldName}(index:Int):${nestedElement.name} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; return ${model.name}.__hxi_struct_slice(this, ${field.offset} + index * ${nestedElement.size}, ${nestedElement.size}); }\n');
								output.add('\tpublic inline function set_${fieldName}(index:Int, value:${nestedElement.name}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; ${model.name}.__hxi_struct_copy(this, ${field.offset} + index * ${nestedElement.size}, value, ${nestedElement.size}); }\n');
								continue;
							}
							if (arrayType(array.element, declarations) != null)
								continue;
							var element = project(abi.classify(array.element), false, profile);
							if (element == null || element.code == 11)
								continue;
							var arrayAccess = structAccess(element.code),
								stride = structSize(element.code);
							if (arrayAccess == null || stride == 0)
								continue;
							structAccesses.set(arrayAccess, {type: element.haxeType, setterType: element.haxeType});
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_${fieldName}(index:Int):${element.haxeType} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; return ${model.name}.__hxi_struct_get${arrayAccess}(this, ${field.offset} + index * $stride); }\n');
							output.add('\tpublic inline function set_${fieldName}(index:Int, value:${element.haxeType}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; ${model.name}.__hxi_struct_set${arrayAccess}(this, ${field.offset} + index * $stride, value); }\n');
							if (element.code == 1 || element.code == 2) {
								usesNestedStructures = true;
								output.add('\tpublic inline function get_${fieldName}_bytes():haxe.io.Bytes return ${model.name}.__hxi_struct_slice(this, ${field.offset}, ${array.length});\n');
								output.add('\tpublic inline function set_${fieldName}_bytes(value:haxe.io.Bytes):Void ${model.name}.__hxi_struct_copy(this, ${field.offset}, value, ${array.length});\n');
							}
							continue;
						}
						var nested = structureType(field.type, declarations, profile);
						if (nested != null) {
							usesNestedStructures = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():${nested.name} return ${model.name}.__hxi_struct_slice(this, ${field.offset}, ${nested.size});\n');
							output.add('\tpublic inline function set_$fieldName(value:${nested.name}):Void ${model.name}.__hxi_struct_copy(this, ${field.offset}, value, ${nested.size});\n');
							continue;
						}
						var value = project(abi.classify(field.type), false, profile);
						if (value != null && value.code == 13) {
							usesUtf8Fields = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():${value.haxeType} return cast ${model.name}.__hxi_struct_get_utf8(this, ${field.offset}, ${value.nullable});\n');
							output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set_utf8(this, ${field.offset}, value, ${value.nullable});\n');
							continue;
						}
						if (value != null && value.code == 11 && value.nativePointer && field.ownership == Borrowed) {
							usesPointerFields = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():${value.haxeType} return cast ${model.name}.__hxi_struct_get_pointer(this, ${field.offset}, ${value.nullable});\n');
							output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set_pointer(this, ${field.offset}, cast value, ${value.nullable});\n');
							continue;
						}
						if (value == null || value.code == 11)
							continue;
						var access = structAccess(value.code);
						if (access == null)
							continue;
						structAccesses.set(access, {type: value.haxeType, setterType: value.haxeType});
						emitDocumentation(output, model, '$name.${field.name}', "\t");
						output.add('\tpublic inline function get_$fieldName():${value.haxeType} return ${model.name}.__hxi_struct_get${access}(this, ${field.offset});\n');
						output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set${access}(this, ${field.offset}, value);\n');
					}
					output.add('}\n');
				case _:
			}
		for (declaration in functionDeclarations)
			switch declaration {
				case Function(name, parameters, _, _, _, _, _, _):
					for (parameter in parameters)
						switch parameter.direction {
							case Out | InOut:
								var value = outputInfo(parameter.type, abi, profile);
								if (!value.structure) {
									var access = structAccess(value.code);
									structAccesses.set(access, {type: value.haxeType, setterType: value.haxeType});
								}
							case OutBuffer(_) | InArray(_):
								usesNestedStructures = true;
							case In:
						}
				case _:
			}
		if (usesNestedStructures) {
			output.add('@:hlNative("haxeon_runtime", "__bytes_alloc") extern function __hxi_struct_alloc(length:Int):haxe.io.Bytes;\n');
			output.add('@:hlNative("haxeon_runtime", "structSlice") extern function __hxi_struct_slice(bytes:haxe.io.Bytes, offset:Int, length:Int):haxe.io.Bytes;\n');
			output.add('@:hlNative("haxeon_runtime", "structCopy") extern function __hxi_struct_copy(bytes:haxe.io.Bytes, offset:Int, value:haxe.io.Bytes, length:Int):Void;\n');
		}
		if (usesPointerFields) {
			output.add('@:hlNative("haxeon_runtime", "structGetPointer") extern function __hxi_struct_get_pointer(bytes:haxe.io.Bytes, offset:Int, nullable:Bool):hl.Abstract<"native_pointer">;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetPointer") extern function __hxi_struct_set_pointer(bytes:haxe.io.Bytes, offset:Int, value:hl.Abstract<"native_pointer">, nullable:Bool):Void;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetBorrowedBytes") extern function __hxi_struct_set_borrowed_bytes(bytes:haxe.io.Bytes, offset:Int, value:haxe.io.Bytes):Void;\n');
		}
		if (usesUtf8Fields) {
			output.add('@:hlNative("haxeon_runtime", "structGetUtf8") extern function __hxi_struct_get_utf8(bytes:haxe.io.Bytes, offset:Int, nullable:Bool):Null<String>;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetUtf8") extern function __hxi_struct_set_utf8(bytes:haxe.io.Bytes, offset:Int, value:Null<String>, nullable:Bool):Void;\n');
		}
		if (usesBorrowedBuffers)
			output.add('@:hlNative("haxeon_runtime", "structCopyPointer") extern function __hxi_struct_copy_pointer(bytes:haxe.io.Bytes, pointerOffset:Int, lengthOffset:Int, lengthBytes:Int):haxe.io.Bytes;\n');
		if (hasCallbacks) {
			output.add('@:hlNative("haxeon_runtime", "native_callback_create") extern function __hxi_callback_create(signature:haxe.io.Bytes, pointerSizes:haxe.io.Bytes, pointerNullable:haxe.io.Bytes, callback:Dynamic):hl.Abstract<"native_callback">;\n');
		}
		for (access in ["I8", "U8", "I16", "U16", "I32", "I64", "F32", "F64"]) {
			var types = structAccesses.get(access);
			if (types == null)
				continue;
			output.add('@:hlNative("haxeon_runtime", "get$access") extern function __hxi_struct_get$access(bytes:haxe.io.Bytes, offset:Int):${types.type};\n');
			output.add('@:hlNative("haxeon_runtime", "set$access") extern function __hxi_struct_set$access(bytes:haxe.io.Bytes, offset:Int, value:${types.setterType}):Void;\n');
		}
		for (fn in abi.functions()) {
			if (isOmitted(omitted, fn.name))
				continue;
			var publicName = projectedFunctionName(fn.name, profile);
			var parameters = switch functions.get(fn.name) {
				case Function(_, value, _, _, _, _, _, _): value;
				case _: throw 'Missing HXI function "${fn.name}"';
			};
			var argumentTypes:Array<String> = [],
				codes:Array<String> = [],
				supported = true;
			for (index in 0...fn.arguments.length) {
				var argument = fn.arguments[index];
				var projected = project(argument, false, profile);
				if (projected == null) {
					supported = false;
					break;
				}
				var outputValue = switch parameters[index].direction {
					case Out | InOut: outputInfo(parameters[index].type, abi, profile);
					case In | InArray(_) | OutBuffer(_): null;
				};
				argumentTypes.push(outputValue == null ? projected.haxeType : outputValue.structure ? outputValue.haxeType : "haxe.io.Bytes");
				codes.push(abiDescriptor(argument, declarations, abi, aggregateDescriptors));
			}
			var result = project(fn.result, true, profile);
			if (!supported || result == null)
				continue;
			var signature = callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi, aggregateDescriptors), fn.callConvention);
			var directed = hasOutput(parameters),
				rawName = directed ? "__hxi_raw_" + fn.name : publicName;
			if (!directed)
				emitDocumentation(output, model, fn.name);
			output.add('@:cNative("${escape(library)}", "${escape(fn.symbol)}", "$signature")\n');
			output.add('extern function $rawName(');
			output.add([for (index in 0...argumentTypes.length) 'arg$index:${argumentTypes[index]}'].join(", "));
			var resultType = result.haxeType;
			if (result.code == 11)
				if (fn.resultPolicy.length != null)
					resultType = result.nullable ? "Null<haxe.io.Bytes>" : "haxe.io.Bytes";
				else
					switch fn.result {
						case PointerValue(_, nullable, opaquePointee, _) if (opaquePointee != null):
							resultType = switch fn.resultPolicy.ownership {
								case Owned(_): nullable ? 'Null<${ownedTypeName(opaquePointee, profile)}>' : ownedTypeName(opaquePointee, profile);
								case Borrowed | Unspecified: result.haxeType;
							};
						case _:
							resultType = result.nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">';
					}
			output.add('):$resultType;\n');
			if (directed) {
				var buffer = outputBuffer(parameters);
				if (buffer == null)
					emitOutputWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, abi, profile, model.documentation.get(fn.name));
				else
					emitBufferWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, buffer, model.documentation.get(fn.name));
			}
			var byteIndex = byteArrayParameter(parameters);
			if (byteIndex != null)
				emitByteSliceWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType,
					directed ? outputWrapperResult(publicName, parameters, resultType, abi, profile) : resultType, abi, byteIndex, profile);
		}
		return output.toString();
	}

	static inline function emitDocumentation(output:StringBuf, model:HxiInterface, name:String, indent:String = ""):Void
		emitDocumentationValue(output, model.documentation.get(name), indent);

	static function emitDocumentationValue(output:StringBuf, documentation:Null<HxiDocumentation>, indent:String = ""):Void {
		if (documentation == null || documentation.raw.length == 0)
			return;
		if (indent.length == 0)
			output.add(documentation.source);
		else if (indent == "\t")
			output.add(documentation.indentedSource);
		else {
			output.add(indent + "/**\n");
			for (line in documentation.lines)
				output.add(indent + " *" + (line.length == 0 ? "" : " " + line) + "\n");
			output.add(indent + " */\n");
		}
	}

	static inline function isOmitted(omitted:Null<Map<String, Bool>>, name:String):Bool
		return omitted != null && omitted.get(name) == true;

	static function hasOutput(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Bool {
		for (parameter in parameters)
			if (parameter.direction != In)
				return true;
		return false;
	}

	static function hasGeneratedOutputResult(parameters:Array<compiler.ffi.HxiModel.HxiParameter>, result:compiler.ffi.HxiModel.HxiType):Bool {
		var outputCount = 0, hasBuffer = false;
		for (parameter in parameters)
			switch parameter.direction {
				case Out | InOut: outputCount++;
				case OutBuffer(_): hasBuffer = true;
				case In | InArray(_):
			}
		var isVoid = switch result {
			case Primitive("void"): true;
			case _: false;
		};
		return hasBuffer ? !isVoid : outputCount > 0 && (outputCount > 1 || !isVoid);
	}

	static function outputBuffer(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Null<{name:String, sizeParameter:String}> {
		for (parameter in parameters)
			switch parameter.direction {
				case OutBuffer(sizeParameter):
					return {name: parameter.name, sizeParameter: sizeParameter};
				case _:
			}
		return null;
	}

	static function outputInfo(type:compiler.ffi.HxiModel.HxiType, abi:HxiAbi, profile:HxiProjectionProfile):{
		haxeType:String,
		code:Int,
		size:Int,
		structure:Bool,
		handle:Bool
	} {
		var element = switch type {
			case Pointer(value): value;
			case _: throw "HXI output parameters require a pointer type";
		};
		var classified = abi.classify(element),
			projected = project(classified, false, profile);
		if (projected == null)
			throw "HXI output parameter has an unsupported pointee type";
		return switch classified {
			case AggregateValue(name, size, _): {
					haxeType: projectedTypeName(name, profile),
					code: 12,
					size: size,
					structure: true,
					handle: false
				};
			case HandleValue(_): {
					haxeType: projected.haxeType,
					code: projected.code,
					size: 4,
					structure: false,
					handle: true
				};
			case IntegerValue(_, _) | EnumerationValue(_, _, _) | FloatValue(_):
				var size = structSize(projected.code);
				if (size == 0)
					throw "HXI output parameter has an unsupported scalar type";
				{
					haxeType: projected.haxeType,
					code: projected.code,
					size: size,
					structure: false,
					handle: false
				};
			case _: throw "HXI output parameters currently support scalar and fixed-structure pointees";
		};
	}

	static function emitOutputWrapper(output:StringBuf, nativeName:String, publicName:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>,
			rawArgumentTypes:Array<String>, resultType:String, abi:HxiAbi, profile:HxiProjectionProfile, documentation:Null<HxiDocumentation>):Void {
		var arguments:Array<String> = [],
			callArguments:Array<String> = [],
			setup:Array<String> = [],
			values:Array<{name:String, type:String, expression:String}> = [];
		var arrayCounts:Map<String, String> = [];
		for (parameter in parameters)
			switch parameter.direction {
				case InArray(count):
					arrayCounts.set(count, parameter.name);
				case _:
			}
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			switch parameter.direction {
				case In:
					var arrayName = arrayCounts.get(parameter.name);
					if (arrayName == null) {
						arguments.push('${parameter.name}:${rawArgumentTypes[index]}');
						callArguments.push(parameter.name);
					} else
						callArguments.push('$arrayName.length');
				case InArray(_):
					var utf8 = utf8ArrayPointer(parameter.type),
						elementType = rawArgumentTypes[index];
					if (elementType == "haxe.io.Bytes" && !utf8) {
						arguments.push('${parameter.name}:haxe.io.Bytes');
						callArguments.push(parameter.name);
					} else {
						arguments.push('${parameter.name}:Array<${utf8 ? "String" : elementType}>');
						setup.push(utf8 ? 'var __array_${parameter.name} = __hxi_struct_alloc(${parameter.name}.length * ${Std.int(abi.pointerBits / 8)}); for (__index in 0...${parameter.name}.length) __hxi_struct_set_utf8(__array_${parameter.name}, __index * ${Std.int(abi.pointerBits / 8)}, ${parameter.name}[__index], false);' : 'var __array_${parameter.name} = $elementType.array(${parameter.name});');
						callArguments.push('__array_${parameter.name}');
					}
				case Out | InOut:
					var info = outputInfo(parameter.type, abi, profile),
						local = "__out_" + parameter.name;
					if (parameter.direction == InOut)
						arguments.push('${parameter.name}:${info.haxeType}');
					if (info.structure)
						setup.push('var $local:${info.haxeType} = ${parameter.direction == InOut ? parameter.name : "new " + info.haxeType + "()"};');
					else {
						setup.push('var $local = haxe.io.Bytes.alloc(${info.size});');
						if (parameter.direction == InOut)
							setup.push('__hxi_struct_set${structAccess(info.code)}($local, 0, ${parameter.name});');
					}
					callArguments.push(local);
					var expression = info.structure ? local : '__hxi_struct_get${structAccess(info.code)}($local, 0)';
					if (info.handle)
						expression = 'cast($expression, ${info.haxeType})';
					values.push({
						name: parameter.name,
						type: info.haxeType,
						expression: expression
					});
				case OutBuffer(_):
					throw "Output buffers require their dedicated wrapper";
			}
		}
		var direct = resultType == "Void" && values.length == 1,
			resultOnly = values.length == 0;
		var wrapperResult = direct ? values[0].type : resultOnly ? resultType : upperFirst(publicName) + "OutResult";
		if (!direct && !resultOnly) {
			output.add('class $wrapperResult {\n');
			var fields:Array<{name:String, type:String}> = [];
			if (resultType != "Void")
				fields.push({name: "status", type: resultType});
			for (value in values)
				fields.push({name: value.name, type: value.type});
			for (field in fields)
				output.add('\tpublic var ${field.name}:${field.type};\n');
			output.add('\tpublic function new(${[for (field in fields) field.name + ":" + field.type].join(", ")}) {\n');
			for (field in fields)
				output.add('\t\tthis.${field.name} = ${field.name};\n');
			output.add('\t}\n}\n');
		}
		emitDocumentationValue(output, documentation);
		output.add('function $publicName(${arguments.join(", ")}):$wrapperResult {\n');
		for (statement in setup)
			output.add('\t$statement\n');
		var call = '__hxi_raw_$nativeName(${callArguments.join(", ")})';
		if (resultType == "Void")
			output.add('\t$call;\n');
		else
			output.add('\tvar __status = $call;\n');
		if (resultOnly) {
			if (resultType != "Void")
				output.add('\treturn __status;\n');
		} else if (direct)
			output.add('\treturn ${values[0].expression};\n');
		else {
			var resultValues = resultType == "Void" ? [] : ["__status"];
			for (value in values)
				resultValues.push(value.expression);
			output.add('\treturn new $wrapperResult(${resultValues.join(", ")});\n');
		}
		output.add('}\n');
	}

	static function emitByteSliceWrapper(output:StringBuf, nativeName:String, publicName:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>,
			rawArgumentTypes:Array<String>, resultType:String, wrapperResult:String, abi:HxiAbi, byteIndex:Null<Int>, profile:HxiProjectionProfile):Void {
		if (byteIndex == null)
			return;
		var byteName = parameters[byteIndex].name,
			offsetName = "offset",
			lengthName = "length",
			used:Map<String, Bool> = [];
		for (parameter in parameters)
			used.set(parameter.name, true);
		if (used.exists(offsetName))
			offsetName = byteName + "_offset";
		if (used.exists(lengthName) || offsetName == lengthName)
			lengthName = byteName + "_length";
		var arguments:Array<String> = [],
			callArguments:Array<String> = [],
			arrayCounts:Map<String, String> = [];
		for (parameter in parameters)
			switch parameter.direction {
				case InArray(count):
					arrayCounts.set(count, parameter.name);
				case _:
			}
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			switch parameter.direction {
				case In:
					if (arrayCounts.get(parameter.name) == null) {
						arguments.push('${parameter.name}:${rawArgumentTypes[index]}');
						callArguments.push(parameter.name);
					}
				case InArray(_):
					if (index == byteIndex) {
						arguments.push('${parameter.name}:haxe.io.Bytes');
						arguments.push('$offsetName:Int');
						arguments.push('$lengthName:Int');
						callArguments.push('haxe.io.Bytes.view(${parameter.name}, $offsetName, $lengthName)');
					} else {
						var utf8 = utf8ArrayPointer(parameter.type),
							elementType = rawArgumentTypes[index];
						arguments.push('${parameter.name}:${utf8 ? "Array<String>" : "Array<" + elementType + ">"}');
						callArguments.push(parameter.name);
					}
				case InOut:
					var info = outputInfo(parameter.type, abi, profile);
					arguments.push('${parameter.name}:${info.haxeType}');
					callArguments.push(parameter.name);
				case Out:
				case OutBuffer(_):
					return;
			}
		}
		output.add('/** Calls $publicName with a validated zero-copy byte slice. */\n');
		output.add('function ${publicName}_slice(${arguments.join(", ")}):$wrapperResult {\n');
		output.add('\tif ($offsetName < 0 || $offsetName > $byteName.length || $lengthName < 0 || $lengthName > $byteName.length - $offsetName) throw "Byte slice is out of bounds";\n');
		output.add('\treturn $publicName(${callArguments.join(", ")});\n');
		output.add('}\n');
	}

	static function outputWrapperResult(name:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>, resultType:String, abi:HxiAbi,
			profile:HxiProjectionProfile):String {
		var count = 0, valueType = "";
		for (parameter in parameters)
			switch parameter.direction {
				case Out | InOut:
					count++;
					if (valueType == "")
						valueType = outputInfo(parameter.type, abi, profile).haxeType;
				case In | InArray(_) | OutBuffer(_):
			}
		return resultType == "Void" && count == 1 ? valueType : count == 0 ? resultType : upperFirst(name) + "OutResult";
	}

	static function byteArrayParameter(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Null<Int> {
		var result:Null<Int> = null;
		for (index in 0...parameters.length)
			switch parameters[index].direction {
				case InArray(_) if (isByteArray(parameters[index].type)):
					if (result != null)
						return null;
					result = index;
				case _:
			}
		return result;
	}

	static function isByteArray(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Const(element): isByteArray(element);
			case Pointer(element): isByteElement(element);
			case _: false;
		};

	static function isByteElement(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Const(element): isByteElement(element);
			case Primitive("u8"): true;
			case _: false;
		};

	static function emitBufferWrapper(output:StringBuf, nativeName:String, publicName:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>,
			rawArgumentTypes:Array<String>, resultType:String, buffer:{
			name:String,
			sizeParameter:String
		}, documentation:Null<HxiDocumentation>):Void {
		var arguments:Array<String> = [],
			queryArguments:Array<String> = [],
			callArguments:Array<String> = [];
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			switch parameter.direction {
				case In:
					arguments.push('${parameter.name}:${rawArgumentTypes[index]}');
					queryArguments.push(parameter.name);
					callArguments.push(parameter.name);
				case InArray(_):
					throw "Input arrays cannot be combined with output buffers";
				case OutBuffer(_):
					queryArguments.push("null");
					callArguments.push("__out_" + buffer.name);
				case InOut:
					queryArguments.push("__out_" + buffer.sizeParameter);
					callArguments.push("__out_" + buffer.sizeParameter);
				case Out:
					throw "Output buffers cannot be mixed with ordinary output parameters";
			}
		}
		var direct = resultType == "Void",
			wrapperResult = direct ? "haxe.io.Bytes" : upperFirst(publicName) + "OutResult";
		if (!direct) {
			output.add('class $wrapperResult {\n');
			output.add('\tpublic var status:$resultType;\n');
			output.add('\tpublic var ${buffer.name}:haxe.io.Bytes;\n');
			output.add('\tpublic function new(status:$resultType, ${buffer.name}:haxe.io.Bytes) {\n');
			output.add('\t\tthis.status = status;\n');
			output.add('\t\tthis.${buffer.name} = ${buffer.name};\n');
			output.add('\t}\n}\n');
		}
		emitDocumentationValue(output, documentation);
		output.add('function $publicName(${arguments.join(", ")}):$wrapperResult {\n');
		output.add('\tvar __out_${buffer.sizeParameter} = haxe.io.Bytes.alloc(4);\n');
		output.add('\t__hxi_struct_setI32(__out_${buffer.sizeParameter}, 0, 0);\n');
		output.add('\t__hxi_raw_$nativeName(${queryArguments.join(", ")});\n');
		output.add('\tvar __capacity:Int = __hxi_struct_getI32(__out_${buffer.sizeParameter}, 0);\n');
		output.add('\tif (__capacity < 0 || __capacity > 268435456) throw "HXI output buffer size exceeds the safety limit";\n');
		output.add('\tvar __out_${buffer.name} = haxe.io.Bytes.alloc(__capacity);\n');
		output.add('\t__hxi_struct_setI32(__out_${buffer.sizeParameter}, 0, __capacity);\n');
		if (resultType == "Void")
			output.add('\t__hxi_raw_$nativeName(${callArguments.join(", ")});\n');
		else
			output.add('\tvar __status = __hxi_raw_$nativeName(${callArguments.join(", ")});\n');
		output.add('\tvar __length:Int = __hxi_struct_getI32(__out_${buffer.sizeParameter}, 0);\n');
		output.add('\tif (__length < 0 || __length > __capacity) throw "HXI output buffer wrote an invalid size";\n');
		output.add('\tif (__length != __capacity) __out_${buffer.name} = __hxi_struct_slice(__out_${buffer.name}, 0, __length);\n');
		if (direct)
			output.add('\treturn __out_${buffer.name};\n');
		else
			output.add('\treturn new $wrapperResult(__status, __out_${buffer.name});\n');
		output.add('}\n');
		}

	static function int64PartAsInt(value:haxe.Int64):String {
		if (haxe.Int64.compare(value, haxe.Int64.parseString("2147483647")) > 0)
			value = haxe.Int64.sub(value, haxe.Int64.parseString("4294967296"));
		return haxe.Int64.toStr(value);
	}

	static function upperFirst(value:String):String
		return value.length == 0 ? value : value.charAt(0).toUpperCase() + value.substr(1);

	static function lowerFirst(value:String):String
		return value.length == 0 ? value : value.charAt(0).toLowerCase() + value.substr(1);

	static function projectedFunctionName(value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.functionNames.get(value);
		if (mapped != null)
			return mapped;
		var stripped = stripPrefix(value, profile.functionPrefix);
		return profile.functionCase == "camel" ? camelCase(stripped) : value;
	}

	static function projectedConstantName(value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.constantNames.get(value);
		if (mapped != null)
			return mapped;
		var stripped = stripPrefix(value, profile.constantPrefix);
		return profile.constantCase == "camel" ? camelCase(stripped) : value;
	}

	static function projectedFieldName(typeName:String, value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.fieldNames.get(typeName + "." + value);
		return mapped == null ? profile.fieldCase == "camel" ? camelCase(value) : value : mapped;
	}

	static function stripPrefix(value:String, prefix:Null<String>):String
		return prefix != null && StringTools.startsWith(value, prefix) ? value.substr(prefix.length) : value;

	static function enumTypeName(value:String, ?profile:HxiProjectionProfile):String {
		if (profile != null) {
			var explicit = profile.enumNames.get(value);
			if (explicit != null)
				return explicit;
		}
		if (profile != null) {
			var mapped = profile.typeNames.get(value);
			if (mapped != null)
				return mapped;
		}
		if (value.indexOf("_") < 0 && value.toLowerCase() != value && value.toUpperCase() != value)
			return value;
		var parts = value.split("_");
		if (profile != null && profile.typePrefix != null && StringTools.startsWith(value, profile.typePrefix))
			parts = value.substr(profile.typePrefix.length).split("_");
		return pascalCase(parts);
	}

	static function projectedTypeName(value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var explicit = profile.typeNames.get(value);
		if (explicit != null)
			return explicit;
		var prefix = profile.typePrefix;
		if (prefix == null || !StringTools.startsWith(value, prefix))
			return value;
		return pascalCase(value.substr(prefix.length).split("_"));
	}

	static function ownedTypeName(value:String, profile:Null<HxiProjectionProfile>):String {
		var projected = projectedTypeName(value, profile),
			separator = projected.lastIndexOf(".");
		return (separator < 0 ? "" : projected.substr(0, separator + 1)) + "Owned" + projected.substr(separator + 1);
	}

	static function enumValuePrefix(values:Array<HxiEnumValue>, ?profile:HxiProjectionProfile):Array<String> {
		if (values.length == 0)
			return [];
		var prefix = values[0].name.split("_");
		for (index in 1...values.length) {
			var parts = values[index].name.split("_"), length = 0;
			while (length < prefix.length && length < parts.length && prefix[length].toUpperCase() == parts[length].toUpperCase())
				length++;
			prefix = prefix.slice(0, length);
		}
		if (prefix.length == values[0].name.split("_").length && profile != null)
			for (configured in profile.enumValuePrefixes) {
				var configuredParts = configured.split("_");
				if (configuredParts.length != 0 && configuredParts[configuredParts.length - 1].length == 0)
					configuredParts.pop();
				if (configuredParts.length < prefix.length) {
					var matches = true;
					for (index in 0...configuredParts.length)
						if (configuredParts[index].toUpperCase() != prefix[index].toUpperCase())
							matches = false;
					if (matches) {
						prefix = prefix.slice(0, configuredParts.length);
						break;
					}
				}
			}
		return prefix;
	}

	static function enumValueName(value:String, prefix:Array<String>, ?enumName:String, ?profile:HxiProjectionProfile):String {
		if (profile != null && enumName != null) {
			var values = profile.enumValueNames.get(enumName);
			if (values != null) {
				var explicit = values.get(value);
				if (explicit != null)
					return explicit;
			}
		}
		var parts = value.split("_"),
			start = prefix.length < parts.length ? prefix.length : 0,
			projected = pascalCase(parts.slice(start));
		if (projected.length == 0)
			projected = pascalCase(parts);
		if (projected.length != 0 && projected.charCodeAt(0) >= "0".code && projected.charCodeAt(0) <= "9".code)
			projected = "Value" + projected;
		return projected;
	}

	static function pascalCase(parts:Array<String>):String {
		var result = "";
		for (part in parts)
			if (part.length != 0) {
				var hasLowerCase = false;
				for (index in 0...part.length) {
					var code = part.charCodeAt(index);
					if (code >= "a".code && code <= "z".code) {
						hasLowerCase = true;
						break;
					}
				}
				var normalized = hasLowerCase ? part : part.toLowerCase();
				result += normalized.charAt(0).toUpperCase() + normalized.substr(1);
			}
		return result;
	}

	static function camelCase(value:String):String {
		var parts = value.split("_");
		if (parts.length == 0)
			return value;
		var first = parts.shift();
		return first.toLowerCase() + pascalCase(parts);
	}

	static function project(value:HxiAbiValue, allowVoid:Bool, ?profile:HxiProjectionProfile):Null<{
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
			case EnumerationValue(name, 64, sign): {
					haxeType: "haxe.Int64",
					nativePointer: false,
					nullable: false,
					code: sign == Unsigned ? 8 : 7
				};
			case EnumerationValue(name, bits, sign) if (bits <= 32):
				var unsigned = sign == Unsigned || sign == PlainChar;
				{
					haxeType: enumTypeName(name, profile),
					nativePointer: false,
					nullable: false,
					code: switch bits {
						case 8: unsigned ? 2 : 1;
						case 16: unsigned ? 4 : 3;
						default: unsigned ? 6 : 5;
					}
				};
			case CallbackValue(name, _, _, nullable): {
					haxeType: nullable ? 'Null<${projectedTypeName(name, profile)}Callback>' : projectedTypeName(name, profile) + "Callback",
					code: 11,
					nativePointer: true,
					nullable: false
				};
			case AggregateValue(name, _, _): {
					haxeType: projectedTypeName(name, profile),
					code: 12,
					nativePointer: false,
					nullable: false
				};
			case HandleValue(name): {
					haxeType: projectedTypeName(name, profile),
					code: 6,
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
			case PointerValue(_, nullable, opaquePointee, structure): {
					haxeType: opaquePointee != null ? (nullable ? 'Null<${projectedTypeName(opaquePointee, profile)}>' : projectedTypeName(opaquePointee,
						profile)) : structure != null ? (nullable ? 'Null<${projectedTypeName(structure, profile)}>' : projectedTypeName(structure,
						profile)) : (nullable ? "Null<haxe.io.Bytes>" : "haxe.io.Bytes"),
					code: 11,
					nativePointer: opaquePointee != null,
					nullable: nullable
				};
			case _: null;
		};

	static function callbackProject(value:HxiAbiValue, ?profile:HxiProjectionProfile):Null<{
		haxeType:String,
		code:Int,
		nativePointer:Bool,
		nullable:Bool
	}>
		return switch value {
			case PointerValue(_, nullable, opaquePointee, structure): {
					haxeType: opaquePointee != null ? (nullable ? 'Null<${projectedTypeName(opaquePointee, profile)}>' : projectedTypeName(opaquePointee,
						profile)) : structure == null ? (nullable ? 'Null<hl.Abstract<"native_pointer">>' : 'hl.Abstract<"native_pointer">') : (nullable ? 'Null<${projectedTypeName(structure, profile)}>' : projectedTypeName(structure,
						profile)),
					code: 11,
					nativePointer: opaquePointee != null || structure == null,
					nullable: nullable
				};
			case _: project(value, false, profile);
		};

	static function escape(value:String):String {
		if (value.indexOf("\\") < 0 && value.indexOf('"') < 0)
			return value;
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');
	}

	static function callSignature(signature:String, convention:String):String
		return convention == "cdecl" ? signature : signature + "@" + convention;

	static function abiDescriptor(value:HxiAbiValue, declarations:Map<String, HxiDeclaration>, abi:HxiAbi,
			aggregateDescriptors:Null<Map<String, String>> = null):String
		return switch value {
			case AggregateValue(name, size, align): aggregateDescriptor(name, size, align, declarations, abi, aggregateDescriptors);
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
			case HandleValue(_): "6";
			case FloatValue(32): "9";
			case FloatValue(64): "10";
			case FloatValue(bits): throw 'Unsupported $bits-bit floating-point ABI value';
			case PointerValue(_, _, _, _) | CallbackValue(_, _, _, _): "11";
			case Utf8Value(nullable): nullable ? "14" : "13";
			case _: throw "Unsupported HXI ABI value";
		};

	static function aggregateDescriptor(name:String, size:Int, align:Int, declarations:Map<String, HxiDeclaration>, abi:HxiAbi,
			aggregateDescriptors:Null<Map<String, String>>):String {
		var cached = aggregateDescriptors == null ? null : aggregateDescriptors.get(name);
		if (cached != null)
			return cached;
		var descriptor = switch declarations.get(name) {
			case Structure(_, _, _, fields, _):
				var ordered = fields.copy();
				ordered.sort(function(left:HxiField, right:HxiField) return fieldOffset(left) - fieldOffset(right));
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
				'{$size;$align;${[for (field in ordered) for (entry in fieldDescriptors(field.type, declarations, abi, aggregateDescriptors)) entry].join(",")}}';
			case _: throw 'Missing HXI structure "$name"';
		};
		if (aggregateDescriptors != null)
			aggregateDescriptors.set(name, descriptor);
		return descriptor;
	}

	static function abiLayout(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):{size:Int, align:Int}
		return switch type {
			case Const(element): abiLayout(element, declarations, abi);
			case Array(element, length):
				var item = abiLayout(element, declarations, abi);
				{size: item.size * length, align: item.align};
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): abiLayout(target, declarations, abi);
					case Handle(_, _, _): {size: 4, align: 4};
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
			case HandleValue(_): {size: 4, align: 4};
			case AggregateValue(_, size, align): {size: size, align: align};
			case VoidValue: throw "Void field has no C layout";
		};

	static function fieldDescriptors(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi,
			aggregateDescriptors:Null<Map<String, String>> = null):Array<String>
		return switch type {
			case Const(element): fieldDescriptors(element, declarations, abi, aggregateDescriptors);
			case Array(element, length): [
					for (_ in 0...length)
						for (entry in fieldDescriptors(element, declarations, abi, aggregateDescriptors))
							entry
				];
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): fieldDescriptors(target, declarations, abi, aggregateDescriptors);
					case Structure(_, _, _, _, _): [abiDescriptor(abi.classify(type), declarations, abi, aggregateDescriptors)];
					case _: [abiDescriptor(abi.classify(type), declarations, abi, aggregateDescriptors)];
				}
			case _: [abiDescriptor(abi.classify(type), declarations, abi, aggregateDescriptors)];
		};

	static function fieldOffset(field:HxiField):Int {
		var offset = field.offset;
		if (offset == null)
			throw 'HXI field "${field.name}" has no offset';
		return offset;
	}

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

	static function structureType(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>,
			profile:Null<HxiProjectionProfile>):Null<{name:String, size:Int}>
		return switch type {
			case Const(element): structureType(element, declarations, profile);
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): structureType(target, declarations, profile);
					case Structure(_, size, _, _, _): {name: projectedTypeName(name, profile), size: size};
					case _: null;
				}
			case _: null;
		};

	static function structurePointerType(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>,
			profile:Null<HxiProjectionProfile>):Null<String>
		return switch type {
			case Nullable(element) | Const(element): structurePointerType(element, declarations, profile);
			case Pointer(element):
				var structure = structureType(element, declarations, profile);
				structure == null ? null : structure.name;
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): structurePointerType(target, declarations, profile);
					case _: null;
				}
			case _: null;
		};

	static function utf8ArrayPointer(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Const(element): utf8ArrayPointer(element);
			case Pointer(element): utf8ArrayElement(element);
			case _: false;
		};

	static function utf8ArrayElement(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Const(element): utf8ArrayElement(element);
			case Primitive("utf8"): true;
			case _: false;
		};

	static function irType(code:Int, result:Bool = false, nativeAbstract:Null<String> = null):IrType
		return switch code {
			case 0: Void;
			case 7 | 8: I64;
			case 9 | 10: F64;
			case 11: result ? Abstract("native_pointer") : nativeAbstract == null ? ManagedBytes : Abstract(nativeAbstract);
			case 12: ManagedBytes;
			case 13: Bytes;
			default: I32;
		};
}
