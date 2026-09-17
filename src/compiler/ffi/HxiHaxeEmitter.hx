package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.ir.Ir.IrType;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiHandleDisposition;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiProjectionProfile.HxiResultErrorProjection;
import compiler.ffi.HaxeProjectionModel.ProjectedOutputStrategy;
import compiler.ffi.HaxeProjectionModel.ProjectedHandleKind;
import compiler.ffi.HaxeProjectionModel.ProjectedEnum;
import compiler.ffi.HaxeProjectionModel.ProjectedCheckedFunction;
import compiler.ffi.HxiSemantics.HxiSemanticParameterKind;
import compiler.ffi.HxiSemantics.HxiSemanticResultKind;

/** Projects bridgeable HXI functions into a synthetic, source-visible module. */
class HxiHaxeEmitter {
	public static function declarationName(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};

	static function projectedEnumValueName(value:ProjectedEnum, nativeName:String):String {
		var projected = Lambda.find(value.values, entry -> entry.nativeName == nativeName);
		return projected == null ?throw 'Missing projected enum value "${value.nativeName}.$nativeName"':projected.name;
	}

	public static function functionNameForSymbol(declarations:Array<HxiDeclaration>, symbol:String):String {
		return switch functionDeclarationForSymbol(declarations, symbol) {
			case Function(name, _, _, _, _, _, _, _): name;
			case _: throw 'Native symbol "$symbol" is not an HXI function';
		};
	}

	static function functionDeclarationForSymbol(declarations:Array<HxiDeclaration>, symbol:String):HxiDeclaration {
		for (declaration in declarations)
			switch declaration {
				case Function(name, _, _, declaredSymbol, _, _, _, _) if ((declaredSymbol == null ? name : declaredSymbol) == symbol):
					return declaration;
				case _:
			}
		throw 'Missing HXI function for native symbol "$symbol"';
	}

	public static function sortedKeys<T>(values:Map<String, T>):Array<String> {
		var result = [for (name in values.keys()) name];
		result.sort(Reflect.compare);
		return result;
	}

	public static function isProjectedType(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Opaque(_, _) | Handle(_, _, _, _) | Structure(_, _, _, _, _) | Enumeration(_, _, _, _, _) | Callback(_, _, _, _, _): true;
			case _: false;
		};

	public static function isEnumeration(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Enumeration(_, _, _, _, _): true;
			case _: false;
		};

	public static function isFunction(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Function(_, _, _, _, _, _, _, _): true;
			case _: false;
		};

	public static function isConstant(declaration:HxiDeclaration):Bool
		return switch declaration {
			case Constant(_, _, _): true;
			case _: false;
		};

	public static function validateTypePath(path:String, entry:String, projected:String, isLocal:Bool):Void {
		var parts:Array<String> = projected == null ? [] : projected.split(".");
		if (parts.length == 0 || (isLocal && parts.length != 1))
			profileError(path, '$entry must be an unqualified type name for a declaration emitted by this interface');
		for (part in parts)
			if (!isHaxeTypeIdentifier(part))
				profileError(path, '$entry projects to invalid Haxe type name "$projected"');
	}

	public static function validateIdentifier(path:String, entry:String, projected:String):Void
		if (!isHaxeIdentifier(projected) || isHaxeBuiltinTypeName(projected))
			profileError(path, '$entry projects to invalid Haxe identifier "$projected"');

	public static function validateEnumValueIdentifier(path:String, entry:String, projected:String):Void
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
			case "abstract" | "break" | "case" | "cast" | "catch" | "class" | "continue" | "default" | "do" | "dynamic" | "else" | "enum" | "extends" |
				"extern" | "false" | "final" | "for" | "from" | "function" | "if" | "implements" | "import" | "in" | "inline" | "interface" | "macro" |
				"new" | "null" | "operator" | "overload" | "override" | "package" | "private" | "public" | "return" | "static" | "super" | "switch" | "this" |
				"throw" | "to" | "true" | "try" | "typedef" | "untyped" | "using" | "var" | "while": true;
			case _: false;
		};

	static function isHaxeBuiltinTypeName(value:String):Bool
		return switch value {
			case "Bool" | "Float" | "Int" | "String" | "Void": true;
			case _: false;
		};

	static function isHaxeTypeIdentifier(value:String):Bool
		return isHaxeIdentifier(value) && !isHaxeBuiltinTypeName(value);

	public static function addProjectedName(path:String, scope:String, projected:String, origin:String, names:Map<String, String>,
			allowBuiltinTypeName:Bool = false):Void {
		if (allowBuiltinTypeName)
			validateEnumValueIdentifier(path, '$scope.$origin', projected);
		else
			validateIdentifier(path, '$scope.$origin', projected);
		var previous = names.get(projected);
		if (previous != null)
			profileError(path, '$scope collision: $origin and $previous both project to "$projected"');
		names.set(projected, origin);
	}

	public static function profileError(path:String, message:String):Void
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
			functionParameters:Map<String, Array<HxiParameter>> = [],
			functionResultTypes:Map<String, HxiType> = [],
			aggregateDescriptors:Map<String, String> = [];
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations)
			switch declaration {
				case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Structure(name, _, _, _, _) | Enumeration(name, _, _, _, _) |
					Callback(name, _, _, _, _):
					declarations.set(name, declaration);
				case Function(name, parameters, result, _, _, _, _, _):
					directed.set(name, hasOutput(parameters) || structureType(result, declarations, profile) != null);
					functionParameters.set(name, parameters);
					functionResultTypes.set(name, result);
				case _:
			}
		for (declaration in model.declarations)
			switch declaration {
				case Function(name, _, resultType, _, _, _, _, _) if (structureType(resultType, declarations, profile) != null):
					directed.set(name, true);
				case _:
			}
		var abi = providedAbi == null ? HxiAbi.forInterface(model, declarations) : providedAbi;
		for (fn in abi.functions())
			switch fn.semantics.result {
				case OwnedHandle(_, _):
					directed.set(fn.name, true);
				case _:
			}
		for (fn in abi.functions()) {
			if (isOmitted(omitted, fn.name))
				continue;
			var arguments:Array<IrType> = [],
				argumentModes:Array<IrCNativeArgumentMode> = [],
				codes:Array<String> = [],
				parameters = functionParameters.get(fn.name),
				abiArguments = fn.arguments,
				supported = parameters != null && parameters.length == fn.arguments.length;
			var outputBufferSizes:Map<String, Bool> = [];
			if (parameters != null)
				for (parameter in parameters)
					switch parameter.direction {
						case OutBuffer(sizeName):
							outputBufferSizes.set(sizeName, true);
						case _:
					}
			for (index in 0...fn.arguments.length) {
				var argument = fn.arguments[index];
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
				var mode = switch fn.semantics.parameters[index].kind {
					case InputValue(_):
						switch abiArguments[index] {
							case AggregateValue(_, size, alignment):
								FixedValue(size, alignment, pointerFreeValue(parameters[index].type, declarations, []));
							case PointerValue(_, _, _, structure) if (structure != null):
								var layout = fixedStructureLayout(structure, declarations);
								layout == null ? Value : FixedInput(layout.size, layout.alignment, pointerFreeOutput(parameters[index].type, declarations));
							case _: Value;
						}
					case InputArray(_, _): Value;
					case InputBytes(lengthName):
						var lengthIndex = parameterIndex(parameters, lengthName);
						isConstPointer(parameters[index].type) ? BytesInput(lengthIndex) : BytesInputOutput(lengthIndex);
					case OutputBuffer(lengthName): BytesOutput(parameterIndex(parameters, lengthName));
					case OutputArray(_, _): Output;
					case OutputValue(_) | OutputHandle(_, _, _):
						var info = outputInfo(parameters[index], abi, profile);
						(info.structure || info.opaquePointer) ? FixedOutput(info.size,
							info.alignment, info.opaquePointer || pointerFreeOutput(parameters[index].type, declarations)) : Output;
					case InOutValue(_) if (outputBufferSizes.exists(parameters[index].name)): BytesSize;
					case InOutValue(_):
						var info = outputInfo(parameters[index], abi, profile);
						(info.structure || info.opaquePointer) ? FixedInputOutput(info.size,
							info.alignment, info.opaquePointer || pointerFreeOutput(parameters[index].type, declarations)) : InputOutput;
					case RetainedCallback(_): Value;
				};
				argumentModes.push(mode);
				codes.push(abiDescriptor(argument, declarations, abi, aggregateDescriptors));
			}
			var abiResult = fn.result,
				returnValue = project(abiResult, true),
				fixedResult:Null<compiler.ir.Ir.IrCNativeFixedLayout> = switch abiResult {
					case AggregateValue(_, size, alignment): {
							size: size,
							alignment: alignment,
							pointerFree: pointerFreeValue(functionResultTypes.get(fn.name), declarations, [])
						};
					case _: null;
				};
			var resultContract:{
				managedBytes:Bool,
				length:Null<String>,
				ownership:String,
				release:Null<String>
			} = switch fn.semantics.result {
				case ManagedBytes(length, _, pointerOwnership, _): {
						managedBytes: true,
						length: length,
						ownership: pointerOwnershipName(pointerOwnership),
						release: ownershipRelease(pointerOwnership)
					};
				case OwnedPointer(_, release): {
						managedBytes: false,
						length: null,
						ownership: "owned",
						release: release
					};
				case BorrowedPointer(_) | BorrowedHandle(_): {
						managedBytes: false,
						length: null,
						ownership: "borrowed",
						release: null
					};
				case OwnedHandle(_, _) | PlainValue(_): {
						managedBytes: false,
						length: null,
						ownership: "unspecified",
						release: null
					};
			};
			if (supported && returnValue != null)
				result.push({
					name: model.name + "." + (directed.get(fn.name) == true ? "__hxi_raw_" + fn.name : projectedFunctionName(fn.name, profile)),
					library: library,
					symbol: fn.symbol,
					signature: callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi, aggregateDescriptors), fn.callConvention),
					arguments: arguments,
					argumentModes: argumentModes,
					result: resultContract.managedBytes || fixedResult != null ? ManagedBytes : irType(returnValue.code, true),
					pointerOwnership: resultContract.ownership,
					pointerRelease: resultContract.release,
					pointerLength: resultContract.length,
					pointerNullable: returnValue.nullable,
					pointerSize: Std.int(abi.pointerBits / 8),
					fixedResult: fixedResult
				});
		}
		return result;
	}

	public static function emit(plan:HaxeProjectionModel):String
		return sourceRaw(plan);

	static function requiredFieldOffset(field:HxiField):Int {
		if (field.offset == null)
			throw 'Missing native offset for HXI field "${field.name}"';
		return field.offset;
	}

	static function sourceRaw(plan:HaxeProjectionModel):String {
		var model = plan.source,
			omitted = plan.omitted,
			visibleDeclarations = plan.visibleDeclarations,
			abi = plan.abi,
			profile = plan.profile;
		var library = model.library;
		if (library == null)
			return "";
		var callbackErrorType = profile != null && profile.callbackErrorType != null ? profile.callbackErrorType : "HxiCallbackError",
			pointerCloseHelper = '__hxi_${model.name}_native_pointer_close',
			pointerIsClosedHelper = '__hxi_${model.name}_native_pointer_is_closed',
			pointerOwnedSlotHelper = '__hxi_${model.name}_native_pointer_owned_from_slot',
			output = new StringBuf(),
			aggregateDescriptors:Map<String, String> = [];
		var structAccesses:Map<String, {type:String, setterType:String}> = [],
			declarations:Map<String, HxiDeclaration> = [],
			opaqueDeclarations:Array<HxiDeclaration> = [],
			functions:Map<String, HxiDeclaration> = [],
			constants:Array<{
				name:String,
				value:String
			}> = [],
			callbackDeclarations:Array<HxiDeclaration> = [],
			enumDeclarations:Array<HxiDeclaration> = [],
			handleDeclarations:Array<HxiDeclaration> = [],
			structureDeclarations:Array<HxiDeclaration> = [],
			functionDeclarations:Array<HxiDeclaration> = [];
		var usesNestedStructures = false,
			usesPointerFields = false,
			usesOwnedPointerSlots = false,
			usesUtf8Fields = false,
			usesUtf8StringCopies = false,
			usesBorrowedBuffers = false,
			hasCallbacks = false;
		var pointerSize = Std.int(abi.pointerBits / 8);
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
				case Handle(name, _, _, _):
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
			output.add('enum abstract $callbackErrorType(Int) from Int to Int { var None = 0; var Exception = 1; var WrongThread = 2; var PointerContract = 3; var AggregateContract = 4; var StringContract = 5; }\n');
		for (declaration in opaqueDeclarations)
			switch declaration {
				case Opaque(name, _):
					var projectedHandle = Lambda.find(plan.handles, handle -> handle.nativeName == name && handle.kind == OpaqueHandle);
					if (projectedHandle == null)
						throw 'Missing projected opaque handle "$name"';
					var projectedName = projectedHandle.name;
					emitDocumentation(output, model, name);
					output.add('abstract $projectedName(hl.Abstract<"native_pointer">) {\n');
					output.add('\tpublic inline function isClosed():Bool return ${model.name}.$pointerIsClosedHelper(cast this);\n');
					output.add('}\n');
					var ownedName = projectedHandle.ownedName;
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
					var projectedCallback = Lambda.find(plan.callbacks, callback -> callback.nativeName == name);
					if (projectedCallback == null)
						throw 'Missing projected callback "$name"';
					var projectedName = projectedCallback.name;
					var argumentTypes:Array<String> = [],
						codes:Array<String> = [],
						pointerSizes:Array<String> = [],
						pointerNullable:Array<String> = [],
						supported = true;
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
					output.add('\tpublic inline function errorKind():$callbackErrorType return ${model.name}.__hxi_callback_error_kind_$name(this);\n');
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
					var projectedEnum = Lambda.find(plan.enums, value -> value.nativeName == name);
					if (projectedEnum == null)
						throw 'Missing projected enum "$name"';
					var underlying = project(abi.classify(representation), false, profile);
					if (underlying == null)
						continue;
					var projectedName = projectedEnum.name,
						bits = switch abi.classify(representation) {
							case IntegerValue(valueBits, _): valueBits;
							case _: 0;
						};
					emitDocumentation(output, model, name);
					if (flags && bits == 64) {
						output.add('abstract $projectedName(haxe.Int64) from haxe.Int64 to haxe.Int64 {\n');
						for (value in values) {
							emitDocumentation(output, model, '$name.${value.name}', "\t");
							var projectedValue = projectedEnumValueName(projectedEnum, value.name),
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
							var projectedValue = projectedEnumValueName(projectedEnum, value.name),
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
				case Handle(name, _, destroySymbol, _):
					var projectedHandle = Lambda.find(plan.handles, handle -> handle.nativeName == name && handle.kind == ValueHandle);
					if (projectedHandle == null)
						throw 'Missing projected value handle "$name"';
					var projectedName = projectedHandle.name;
					emitDocumentation(output, model, name);
					// Keep handles nominal at the Haxe boundary. Explicit construction and
					// rawValue() provide deliberate escape hatches without allowing two
					// unrelated resource handles to flow through their shared Int ABI.
					output.add('abstract $projectedName(Int) {\n');
					output.add('\tpublic inline function new(value:Int = 0) this = value;\n');
					output.add('\tpublic static inline function invalid():$projectedName return new $projectedName();\n');
					output.add('\tpublic inline function isValid():Bool return cast(this, Int) != 0;\n');
					output.add('\tpublic inline function rawValue():Int return cast this;\n');
					output.add('}\n');
					var owned = projectedHandle.owned;
					if (owned != null) {
						var ownedName = owned.name,
							destroySymbol = owned.destroy;
						var destroyFunction = functionDeclarationForSymbol(model.declarations, destroySymbol),
							destroyName = switch destroyFunction {
								case Function(value, _, _, _, _, _, _, _): value;
								case _: throw 'Native symbol "$destroySymbol" is not an HXI function';
							},
							destroyResult = switch destroyFunction {
								case Function(_, _, value, _, _, _, _, _): value;
								case _: throw 'Native symbol "$destroySymbol" is not an HXI function';
							},
							closeResultValue = switch abi.classify(destroyResult, true) {
								case VoidValue: null;
								case value:
									var projected = project(value, true, profile);
									if (projected == null)
										throw 'Unsupported destroy result for handle "$name"';
									projected.haxeType;
							},
							destroyFunctionName = projectedFunctionName(destroyName, profile),
							closeReturnType = closeResultValue == null ? "Bool" : 'Null<$closeResultValue>';
						output.add('class $ownedName {\n');
						output.add('\tprivate var __handle:$projectedName;\n');
						output.add('\tprivate var __closed:Bool = false;\n');
						output.add('\tprivate function new(handle:$projectedName) this.__handle = handle;\n');
						output.add('\tpublic static function adopt(handle:$projectedName):$ownedName return new $ownedName(handle);\n');
						output.add('\tpublic function borrow():$projectedName return this.__handle;\n');
						output.add('\tpublic function rawValue():Int return this.__handle.rawValue();\n');
						output.add('\tpublic function isClosed():Bool return this.__closed;\n');
						output.add('\tpublic function close():$closeReturnType {\n');
						output.add('\t\tif (this.__closed) return ${closeResultValue == null ? "false" : "null"};\n');
						output.add('\t\tthis.__closed = true;\n');
						output.add('\t\tvar __value = this.__handle;\n');
						output.add('\t\tthis.__handle = $projectedName.invalid();\n');
						if (closeResultValue == null) {
							output.add('\t\tif (__value.isValid()) ${model.name}.$destroyFunctionName(__value);\n');
							output.add('\t\treturn true;\n');
						} else {
							output.add('\t\tif (__value.isValid()) return ${model.name}.$destroyFunctionName(__value);\n');
							output.add('\t\treturn null;\n');
						}
						output.add('\t}\n');
						output.add('}\n');
					}
				case _:
			}
		for (declaration in structureDeclarations)
			switch declaration {
				case Structure(name, size, _, fields, _):
					var projectedStruct = Lambda.find(plan.structures, value -> value.nativeName == name);
					if (projectedStruct == null)
						throw 'Missing projected structure "$name"';
					var projectedName = projectedStruct.name,
						rootSlots = Std.int(Math.ceil(size / pointerSize));
					emitDocumentation(output, model, name);
					output.add('/** Managed storage; this struct value may be retained and reused across native calls. Native pointers derived from it are call-scoped. */\n');
					output.add('abstract $projectedName(haxe.io.Bytes) from haxe.io.Bytes to haxe.io.Bytes {\n');
					output.add('\tpublic static inline function size():Int return $size;\n');
					output.add('\tpublic static function __hxi_attach(bytes:haxe.io.Bytes):$projectedName { var roots:Array<haxe.io.Bytes> = []; for (__slot in 0...${rootSlots + 1}) roots.push(null); roots[0] = bytes; return cast ${model.name}.__hxi_struct_with_roots(bytes, roots); }\n');
					output.add('\tpublic static function array(values:Array<$projectedName>):$projectedName { var bytes = ${model.name}.__hxi_struct_alloc(values.length * $size); var roots:Array<haxe.io.Bytes> = []; for (__slot in 0...(values.length * $rootSlots + 1)) roots.push(null); roots[0] = bytes; var result:$projectedName = cast ${model.name}.__hxi_struct_with_roots(bytes, roots); for (index in 0...values.length) { ${model.name}.__hxi_struct_copy(bytes, index * $size, values[index], $size); var sourceRoots = ${model.name}.__hxi_struct_get_roots(values[index]); for (__slot in 1...${rootSlots + 1}) { var __retained = sourceRoots[__slot]; if (__retained != null) roots[index * $rootSlots + __slot] = __retained; } } return result; }\n');
					usesNestedStructures = true;
					var sizeField = Lambda.find(fields, field -> field.structSize),
						sizeInitialization = sizeField == null ? "" : ' ${model.name}.__hxi_struct_setI32(bytes, ${requiredFieldOffset(sizeField)}, $size);';
					output.add('\tpublic inline function new() { var bytes = haxe.io.Bytes.alloc($size); for (index in 0...$size) bytes.set(index, 0);$sizeInitialization var roots:Array<haxe.io.Bytes> = []; for (__slot in 0...${rootSlots + 1}) roots.push(null); roots[0] = bytes; this = ${model.name}.__hxi_struct_with_roots(bytes, roots); }\n');
					for (field in fields) {
						var projectedField = Lambda.find(projectedStruct.fields, value -> value.nativeName == field.name);
						if (projectedField == null)
							throw 'Missing projected field "$name.${field.name}"';
						var fieldName = projectedField.name,
							fieldOffset = requiredFieldOffset(field);
						if (field.lengthField != null) {
							var pointed = structurePointerType(field.type, declarations, profile);
							if (pointed != null) {
								usesPointerFields = true;
								var lengthField = Lambda.find(fields, candidate -> candidate.name == field.lengthField);
								if (lengthField == null)
									throw 'Missing length field "${field.lengthField}"';
								var lengthValue = abi.classify(lengthField.type),
									lengthAccess = switch lengthValue {
										case IntegerValue(64, _): "I64";
										case IntegerValue(_, _): "I32";
										case _: throw 'Invalid length field "${lengthField.name}"';
									},
									lengthExpression = lengthAccess == "I64" ? "haxe.Int64.ofInt(values.length)" : "values.length",
									rootSlot = Std.int(fieldOffset / pointerSize) + 1;
								emitDocumentation(output, model, '$name.${field.name}', "\t");
								output.add('\tpublic function set_$fieldName(values:Array<$pointed>):Void { var bytes = $pointed.array(values); ${model.name}.__hxi_struct_set_borrowed_bytes(this, $fieldOffset, bytes); ${model.name}.__hxi_struct_get_roots(this)[$rootSlot] = bytes; ${model.name}.__hxi_struct_set$lengthAccess(this, ${requiredFieldOffset(lengthField)}, $lengthExpression); }\n');
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
							var utf8Array = utf8PointerArray(field.type);
							if (utf8Array) {
								usesUtf8Fields = true;
								usesUtf8StringCopies = true;
								usesPointerFields = true;
								var lengthAccess = lengthBytes == 8 ? "I64" : "I32",
									lengthExpression = lengthBytes == 8 ? "haxe.Int64.ofInt(values.length)" : "values.length",
									countExpression = lengthBytes == 8 ? 'haxe.Int64.toInt(${model.name}.__hxi_struct_getI64(this, ${requiredFieldOffset(lengthField)}))' : '${model.name}.__hxi_struct_getI32(this, ${requiredFieldOffset(lengthField)})',
									rootSlot = Std.int(fieldOffset / pointerSize) + 1;
								emitDocumentation(output, model, '$name.${field.name}', "\t");
								output.add('\tpublic function get_$fieldName():Array<String> { var bytes = ${model.name}.__hxi_struct_get_roots(this)[$rootSlot]; var count = $countExpression; var values:Array<String> = []; if (bytes != null) for (index in 0...count) values.push(${model.name}.__hxi_struct_get_utf8(bytes, index * $pointerSize, false)); return values; }\n');
								output.add('\tpublic function set_$fieldName(values:Array<String>):Void { var storage = ${model.name}.__hxi_struct_alloc(values.length * $pointerSize); var roots:Array<haxe.io.Bytes> = []; for (__slot in 0...values.length + 1) roots.push(null); roots[0] = storage; var bytes:haxe.io.Bytes = ${model.name}.__hxi_struct_with_roots(storage, roots); for (index in 0...values.length) { var __text = ${model.name}.__hxi_struct_utf8_copy(values[index]); ${model.name}.__hxi_struct_set_borrowed_bytes(bytes, index * $pointerSize, __text); roots[index + 1] = __text; } ${model.name}.__hxi_struct_set_borrowed_bytes(this, $fieldOffset, bytes); ${model.name}.__hxi_struct_get_roots(this)[$rootSlot] = bytes; ${model.name}.__hxi_struct_set$lengthAccess(this, ${requiredFieldOffset(lengthField)}, $lengthExpression); }\n');
								continue;
							}
							usesBorrowedBuffers = true;
							usesPointerFields = true;
							var lengthAccess = lengthBytes == 8 ? "I64" : "I32",
								rootSlot = Std.int(fieldOffset / pointerSize) + 1,
								lengthExpression = lengthBytes == 8 ? "haxe.Int64.ofInt(value.length)" : "value.length";
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_${fieldName}_bytes():haxe.io.Bytes return ${model.name}.__hxi_struct_copy_pointer(this, $fieldOffset, ${requiredFieldOffset(lengthField)}, $lengthBytes);\n');
							output.add('\tpublic function set_${fieldName}_bytes(value:haxe.io.Bytes):Void { ${model.name}.__hxi_struct_set_borrowed_bytes(this, $fieldOffset, value); ${model.name}.__hxi_struct_get_roots(this)[$rootSlot] = value; ${model.name}.__hxi_struct_set$lengthAccess(this, ${requiredFieldOffset(lengthField)}, $lengthExpression); }\n');
							continue;
						}
						var array = arrayType(field.type, declarations);
						if (array != null) {
							var nestedElement = structureType(array.element, declarations, profile);
							if (nestedElement != null) {
								usesNestedStructures = true;
								var nestedSlots = Std.int(Math.ceil(nestedElement.size / pointerSize)),
									baseSlot = Std.int(fieldOffset / pointerSize);
								emitDocumentation(output, model, '$name.${field.name}', "\t");
								output.add('\tpublic function get_${fieldName}(index:Int):${nestedElement.name} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; var offset = $fieldOffset + index * ${nestedElement.size}; var bytes = ${model.name}.__hxi_struct_slice(this, offset, ${nestedElement.size}); var roots:Array<haxe.io.Bytes> = []; for (__root in 0...${nestedSlots + 1}) roots.push(null); roots[0] = bytes; var sourceRoots = ${model.name}.__hxi_struct_get_roots(this); var result:${nestedElement.name} = cast ${model.name}.__hxi_struct_with_roots(bytes, roots); for (__slot in 1...${nestedSlots + 1}) { var __retained = sourceRoots[$baseSlot + index * $nestedSlots + __slot]; if (__retained != null) roots[__slot] = __retained; } return result; }\n');
								output.add('\tpublic function set_${fieldName}(index:Int, value:${nestedElement.name}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; var offset = $fieldOffset + index * ${nestedElement.size}; ${model.name}.__hxi_struct_copy(this, offset, value, ${nestedElement.size}); var destinationRoots = ${model.name}.__hxi_struct_get_roots(this); var sourceRoots = ${model.name}.__hxi_struct_get_roots(value); for (__slot in 1...${nestedSlots + 1}) destinationRoots[$baseSlot + index * $nestedSlots + __slot] = sourceRoots[__slot]; }\n');
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
							var arrayIsHandle = isHandleAbi(abi.classify(array.element)),
								arrayRead = arrayIsHandle ? 'cast ${model.name}.__hxi_struct_get${arrayAccess}(this, $fieldOffset + index * $stride)' : '${model.name}.__hxi_struct_get${arrayAccess}(this, $fieldOffset + index * $stride)',
								arrayWrite = arrayIsHandle ? "value.rawValue()" : "value";
							structAccesses.set(arrayAccess, {type: structAccessHaxeType(arrayAccess), setterType: structAccessHaxeType(arrayAccess)});
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_${fieldName}(index:Int):${element.haxeType} { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; return $arrayRead; }\n');
							output.add('\tpublic inline function set_${fieldName}(index:Int, value:${element.haxeType}):Void { if (index < 0 || index >= ${array.length}) throw "HXI array index out of bounds"; ${model.name}.__hxi_struct_set${arrayAccess}(this, $fieldOffset + index * $stride, $arrayWrite); }\n');
							if (element.code == 1 || element.code == 2) {
								usesNestedStructures = true;
								output.add('\tpublic inline function get_${fieldName}_bytes():haxe.io.Bytes return ${model.name}.__hxi_struct_slice(this, $fieldOffset, ${array.length});\n');
								output.add('\tpublic inline function set_${fieldName}_bytes(value:haxe.io.Bytes):Void ${model.name}.__hxi_struct_copy(this, $fieldOffset, value, ${array.length});\n');
							}
							continue;
						}
						var nested = structureType(field.type, declarations, profile);
						if (nested != null) {
							usesNestedStructures = true;
							var nestedSlots = Std.int(Math.ceil(nested.size / pointerSize)),
								baseSlot = Std.int(fieldOffset / pointerSize);
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic function get_$fieldName():${nested.name} { var bytes = ${model.name}.__hxi_struct_slice(this, $fieldOffset, ${nested.size}); var roots:Array<haxe.io.Bytes> = []; for (__root in 0...${nestedSlots + 1}) roots.push(null); roots[0] = bytes; var sourceRoots = ${model.name}.__hxi_struct_get_roots(this); var result:${nested.name} = cast ${model.name}.__hxi_struct_with_roots(bytes, roots); for (__slot in 1...${nestedSlots + 1}) { var __retained = sourceRoots[$baseSlot + __slot]; if (__retained != null) roots[__slot] = __retained; } return result; }\n');
							output.add('\tpublic function set_$fieldName(value:${nested.name}):Void { ${model.name}.__hxi_struct_copy(this, $fieldOffset, value, ${nested.size}); var destinationRoots = ${model.name}.__hxi_struct_get_roots(this); var sourceRoots = ${model.name}.__hxi_struct_get_roots(value); for (__slot in 1...${nestedSlots + 1}) destinationRoots[$baseSlot + __slot] = sourceRoots[__slot]; }\n');
							continue;
						}
						var value = project(abi.classify(field.type), false, profile);
						if (value != null && value.code == 15) {
							structAccesses.set("I32", {type: "Int", setterType: "Int"});
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():Bool return ${model.name}.__hxi_struct_getI32(this, $fieldOffset) != 0;\n');
							output.add('\tpublic inline function set_$fieldName(value:Bool):Void ${model.name}.__hxi_struct_setI32(this, $fieldOffset, value ? 1 : 0);\n');
							continue;
						}
						if (value != null && value.code == 13) {
							usesUtf8Fields = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():${value.haxeType} return cast ${model.name}.__hxi_struct_get_utf8(this, $fieldOffset, ${value.nullable});\n');
							output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set_utf8(this, $fieldOffset, value, ${value.nullable});\n');
							continue;
						}
						if (value != null && value.code == 11 && value.nativePointer && field.ownership == Borrowed) {
							usesPointerFields = true;
							emitDocumentation(output, model, '$name.${field.name}', "\t");
							output.add('\tpublic inline function get_$fieldName():${value.haxeType} return cast ${model.name}.__hxi_struct_get_pointer(this, $fieldOffset, ${value.nullable});\n');
							output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set_pointer(this, $fieldOffset, cast value, ${value.nullable});\n');
							continue;
						}
						if (value == null || value.code == 11)
							continue;
						var access = structAccess(value.code);
						if (access == null)
							continue;
						var isHandle = isHandleAbi(abi.classify(field.type)),
							readExpression = isHandle ? 'cast ${model.name}.__hxi_struct_get${access}(this, $fieldOffset)' : '${model.name}.__hxi_struct_get${access}(this, $fieldOffset)',
							writeExpression = isHandle ? "value.rawValue()" : "value";
						structAccesses.set(access, {type: structAccessHaxeType(access), setterType: structAccessHaxeType(access)});
						emitDocumentation(output, model, '$name.${field.name}', "\t");
						output.add('\tpublic inline function get_$fieldName():${value.haxeType} return $readExpression;\n');
						output.add('\tpublic inline function set_$fieldName(value:${value.haxeType}):Void ${model.name}.__hxi_struct_set${access}(this, $fieldOffset, $writeExpression);\n');
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
								var value = outputInfo(parameter, abi, profile);
								if (value.opaquePointer) {
									usesPointerFields = true;
									if (value.owned)
										usesOwnedPointerSlots = true;
								} else if (!value.structure) {
									var access = structAccess(value.code);
									structAccesses.set(access, {type: structAccessHaxeType(access), setterType: structAccessHaxeType(access)});
								}
							case InArray(_) if (utf8ArrayPointer(parameter.type)):
								usesUtf8StringCopies = true;
								usesPointerFields = true;
							case OutBuffer(_) | InArray(_):
								usesNestedStructures = true;
							case OutArray(_):
								usesNestedStructures = true;
								usesUtf8Fields = true;
							case In:
						}
				case _:
			}
		if (usesNestedStructures) {
			output.add('@:hlNative("haxeon_runtime", "__bytes_alloc") extern function __hxi_struct_alloc(length:Int):haxe.io.Bytes;\n');
			output.add('@:hlNative("haxeon_runtime", "structSlice") extern function __hxi_struct_slice(bytes:haxe.io.Bytes, offset:Int, length:Int):haxe.io.Bytes;\n');
			output.add('@:hlNative("haxeon_runtime", "structCopy") extern function __hxi_struct_copy(bytes:haxe.io.Bytes, offset:Int, value:haxe.io.Bytes, length:Int):Void;\n');
		}
		if (structureDeclarations.length > 0 || usesUtf8StringCopies) {
			output.add('@:hlNative("haxeon_runtime", "structWithRoots") extern function __hxi_struct_with_roots(bytes:haxe.io.Bytes, roots:Array<haxe.io.Bytes>):haxe.io.Bytes;\n');
			output.add('@:hlNative("haxeon_runtime", "structGetRoots") extern function __hxi_struct_get_roots(bytes:haxe.io.Bytes):Array<haxe.io.Bytes>;\n');
		}
		if (usesPointerFields) {
			output.add('@:hlNative("haxeon_runtime", "structGetPointer") extern function __hxi_struct_get_pointer(bytes:haxe.io.Bytes, offset:Int, nullable:Bool):hl.Abstract<"native_pointer">;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetPointer") extern function __hxi_struct_set_pointer(bytes:haxe.io.Bytes, offset:Int, value:hl.Abstract<"native_pointer">, nullable:Bool):Void;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetBorrowedBytes") extern function __hxi_struct_set_borrowed_bytes(bytes:haxe.io.Bytes, offset:Int, value:haxe.io.Bytes):Void;\n');
		}
		if (usesOwnedPointerSlots)
			output.add('@:hlNative("haxeon_runtime", "native_pointer_owned_from_slot") extern function $pointerOwnedSlotHelper(bytes:haxe.io.Bytes, offset:Int, library:String, symbol:String, signature:String, release:String, nullable:Bool):hl.Abstract<"native_pointer">;\n');
		if (usesUtf8Fields) {
			output.add('@:hlNative("haxeon_runtime", "structGetUtf8") extern function __hxi_struct_get_utf8(bytes:haxe.io.Bytes, offset:Int, nullable:Bool):Null<String>;\n');
			output.add('@:hlNative("haxeon_runtime", "structSetUtf8") extern function __hxi_struct_set_utf8(bytes:haxe.io.Bytes, offset:Int, value:Null<String>, nullable:Bool):Void;\n');
		}
		if (usesUtf8StringCopies)
			output.add('@:hlNative("haxeon_runtime", "structUtf8Copy") extern function __hxi_struct_utf8_copy(value:String):haxe.io.Bytes;\n');
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
		for (projectedFunction in plan.functions) {
			var fn = projectedFunction.nativeSignature;
			var publicName = projectedFunction.name;
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
					case Out | InOut: outputInfo(parameters[index], abi, profile);
					case In | InArray(_) | OutArray(_) | OutBuffer(_): null;
				};
				argumentTypes.push(outputValue == null ? projected.haxeType : outputValue.structure ? outputValue.haxeType : "haxe.io.Bytes");
				codes.push(abiDescriptor(argument, declarations, abi, aggregateDescriptors));
			}
			var result = project(fn.result, true, profile);
			if (!supported || result == null)
				continue;
			var signature = callSignature(codes.join(",") + ">" + abiDescriptor(fn.result, declarations, abi, aggregateDescriptors), fn.callConvention),
				declaredResult = switch functions.get(fn.name) {
					case Function(_, _, value, _, _, _, _, _): value;
					case _: throw 'Missing HXI function "${fn.name}"';
				},
				aggregateResult = structureType(declaredResult, declarations, profile);
			var ownedHandleResult = projectedFunction.ownedResult == null ? null : projectedFunction.ownedResult.name,
				hasOutputs = hasOutput(parameters),
				rawName = projectedFunction.rawName;
			if (projectedFunction.rawName == publicName)
				emitDocumentation(output, model, fn.name);
			for (parameter in parameters)
				if (parameter.retained)
					output.add('/** Native retains this callback beyond the call; follow the API-specific detach or release contract. */\n');
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
			if (projectedFunction.hasOutputParameters) {
				var nativeSymbol = switch functions.get(fn.name) {
					case Function(_, _, _, symbol, _, _, _, _): symbol == null ? fn.name : symbol;
					case _: fn.name;
				};
				var array = outputArray(parameters),
					buffer = outputBuffer(parameters);
				switch projectedFunction.outputStrategy {
					case OutputArray if (array != null):
						emitOutputArrayWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, array, abi, profile,
							model.documentation.get(fn.name));
					case OutputBuffer if (buffer != null):
						emitBufferWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, buffer, model.documentation.get(fn.name));
					case OutputValues:
						emitOutputWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, abi, profile, library, nativeSymbol, signature,
							pointerOwnedSlotHelper, model.documentation.get(fn.name), ownedHandleResult, aggregateResult == null ? null : aggregateResult.name);
					case OutputArray:
						throw 'Planned output array metadata is missing for "${fn.name}"';
					case OutputBuffer:
						throw 'Planned output buffer metadata is missing for "${fn.name}"';
					case NoOutputWrapper:
						throw 'Output parameters were not normalized for "${fn.name}"';
				}
			} else if (ownedHandleResult != null) {
				emitOwnedHandleResultWrapper(output, publicName, rawName, argumentTypes, ownedHandleResult, model.documentation.get(fn.name));
			} else if (aggregateResult != null) {
				emitAggregateResultWrapper(output, publicName, rawName, argumentTypes, aggregateResult.name, model.documentation.get(fn.name));
			}
			var byteIndex = projectedFunction.byteSliceName == null ? null : byteArrayParameter(parameters);
			if (byteIndex != null) {
				var byteWrapperResult = hasOutputs ? outputWrapperResult(publicName, parameters, resultType, abi,
					profile) : ownedHandleResult == null ? aggregateResult == null ? resultType : aggregateResult.name : ownedHandleResult;
				emitByteSliceWrapper(output, fn.name, publicName, parameters, argumentTypes, resultType, byteWrapperResult, abi, byteIndex, profile);
			}
			if (projectedFunction.checked != null)
				emitCheckedResultWrapper(output, model, fn.name, publicName, parameters, argumentTypes, projectedFunction.checked, abi, profile);
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

	public static inline function isOmitted(omitted:Null<Map<String, Bool>>, name:String):Bool
		return omitted != null && omitted.get(name) == true;

	public static function resultErrorProjection(type:HxiType, profile:Null<HxiProjectionProfile>):Null<HxiResultErrorProjection>
		return if (profile == null) null else switch type {
			case Named(name): profile.resultPolicies.get(name);
			case _: null;
		};

	static function emitCheckedResultWrapper(output:StringBuf, model:HxiInterface, nativeName:String, publicName:String,
			parameters:Array<compiler.ffi.HxiModel.HxiParameter>, rawArgumentTypes:Array<String>, planned:ProjectedCheckedFunction, abi:HxiAbi,
			profile:HxiProjectionProfile):Void {
		var policy = planned.policy;
		var array = outputArray(parameters),
			buffer = outputBuffer(parameters),
			arrayCounts:Map<String, String> = [],
			arguments:Array<String> = [],
			callArguments:Array<String> = [];
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
					if (!arrayCounts.exists(parameter.name)) {
						arguments.push('${parameter.name}:${rawArgumentTypes[index]}');
						callArguments.push(parameter.name);
					}
				case InArray(_):
					var utf8 = utf8ArrayPointer(parameter.type),
						elementType = rawArgumentTypes[index],
						argumentType = elementType == "haxe.io.Bytes"
							&& !utf8 ? "haxe.io.Bytes" : 'Array<${utf8 ? "String" : elementType}>';
					arguments.push('${parameter.name}:$argumentType');
					callArguments.push(parameter.name);
				case InOut:
					if ((array == null || parameter.name != array.countParameter)
						&& (buffer == null || parameter.name != buffer.sizeParameter)) {
						var info = outputInfo(parameter, abi, profile);
						arguments.push('${parameter.name}:${info.haxeType}');
						callArguments.push(parameter.name);
					}
				case Out | OutArray(_) | OutBuffer(_):
			}
		}

		var outputFields:Array<{name:String, type:String}> = [for (output in planned.outputs) {name: output.parameter, type: output.type}],
			statusField = "__result",
			hasOutputs = outputFields.length > 0,
			returnType = planned.returnType,
			returnExpression = if (outputFields.length == 1) '__result.${outputFields[0].name}' else if (outputFields.length > 1) "{"
				+ [for (field in outputFields) field.name + ": __result." + field.name].join(", ") + "}" else "",
			resultName = switch nativeFunctionResult(model.declarations, nativeName) {
				case Named(name): name;
				case _: throw 'Result policy applied to non-enum result for "$nativeName"';
			},
			success = resultSuccessMember(model.declarations, resultName, policy.successValue, profile),
			diagnostic = policy.diagnosticFunction == null ? "null" : projectedFunctionName(policy.diagnosticFunction, profile),
			checkedName = planned.name;

		output.add('/** Calls $publicName and throws the configured error type when its result is not successful. */\n');
		output.add('function $checkedName(${arguments.join(", ")}):$returnType {\n');
		output.add('\tvar __result = $publicName(${callArguments.join(", ")});\n');
		if (hasOutputs) {
			output.add('\tvar __status = __result.status;\n');
			statusField = "__status";
		}
		output.add('\tif ($statusField != ${enumTypeName(resultName, profile)}.$success) {\n');
		if (policy.diagnosticFunction != null)
			output.add('\t\tvar __diagnostic = $diagnostic();\n');
		output.add('\t\tthrow new ${policy.errorType}($statusField, "${escape(publicName)}", ${policy.diagnosticFunction == null ? "null" : "__diagnostic"});\n');
		output.add('\t}\n');
		if (hasOutputs)
			output.add('\treturn $returnExpression;\n');
		output.add('}\n');
	}

	static function nativeFunctionResult(declarations:Array<HxiDeclaration>, name:String):HxiType {
		for (declaration in declarations)
			switch declaration {
				case Function(functionName, _, result, _, _, _, _, _) if (functionName == name):
					return result;
				case _:
			}
		throw 'Missing HXI function "$name"';
	}

	static function resultSuccessMember(declarations:Array<HxiDeclaration>, enumName:String, nativeValue:String, profile:HxiProjectionProfile):String {
		for (declaration in declarations)
			switch declaration {
				case Enumeration(name, _, _, values, _) if (name == enumName):
					var prefix = enumValuePrefix(values, profile);
					for (value in values)
						if (value.name == nativeValue)
							return enumValueName(value.name, prefix, name, profile);
				case _:
			}
		throw 'Missing success enum value "$enumName.$nativeValue"';
	}

	public static function hasOutput(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Bool {
		for (parameter in parameters)
			if (parameter.direction != In)
				return true;
		return false;
	}

	public static function hasGeneratedOutputResult(parameters:Array<compiler.ffi.HxiModel.HxiParameter>, result:compiler.ffi.HxiModel.HxiType):Bool {
		var outputCount = 0,
			hasBuffer = false,
			array = outputArray(parameters);
		for (parameter in parameters)
			switch parameter.direction {
				case Out:
					outputCount++;
				case InOut if (array == null || parameter.name != array.countParameter):
					outputCount++;
				case InOut:
				case OutBuffer(_):
					hasBuffer = true;
				case OutArray(_):
					outputCount++;
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

	static function outputArray(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Null<{name:String, countParameter:String}> {
		for (parameter in parameters)
			switch parameter.direction {
				case OutArray(countParameter):
					return {name: parameter.name, countParameter: countParameter};
				case _:
			}
		return null;
	}

	static inline function outputArrayType():String
		return "Array<Null<String>>";

	static function pointerOwnershipName(value:HxiOwnership):String
		return switch value {
			case Unspecified: "unspecified";
			case Borrowed: "borrowed";
			case Owned(_): "owned";
		};

	static function ownershipRelease(value:HxiOwnership):Null<String>
		return switch value {
			case Owned(release): release;
			case Borrowed | Unspecified: null;
		};

	static function ownedValueHandleType(type:HxiAbiValue, disposition:HxiHandleDisposition, profile:HxiProjectionProfile):Null<String> {
		return switch disposition {
			case Owned:
				switch type {
					case HandleValue(name): ownedTypeName(name, profile);
					case _: throw "Validated owned HXI value handle did not classify as a handle";
				}
			case Unspecified:
				null;
		};
	}

	static function outputInfo(parameter:compiler.ffi.HxiModel.HxiParameter, abi:HxiAbi, profile:HxiProjectionProfile):{
		haxeType:String,
		rawHaxeType:String,
		code:Int,
		size:Int,
		alignment:Int,
		structure:Bool,
		handle:Bool,
		ownedValueHandle:Bool,
		opaquePointer:Bool,
		nullable:Bool,
		owned:Bool
	} {
		var element = switch parameter.type {
			case Pointer(value): value;
			case _: throw "HXI output parameters require a pointer type";
		};
		var classified = abi.classify(element),
			projected = project(classified, false, profile);
		if (projected == null)
			throw "HXI output parameter has an unsupported pointee type";
		return switch classified {
			case AggregateValue(name, size, alignment): {
					haxeType: projectedTypeName(name, profile),
					rawHaxeType: projectedTypeName(name, profile),
					code: 12,
					size: size,
					alignment: alignment,
					structure: true,
					handle: false,
					ownedValueHandle: false,
					opaquePointer: false,
					nullable: false,
					owned: false
				};
			case HandleValue(name):
				var ownedValueHandle = parameter.handleDisposition == Owned,
					projectedName = projectedTypeName(name, profile),
					haxeName = ownedValueHandle ? ownedTypeName(name, profile) : projectedName;
				{
					haxeType: haxeName,
					rawHaxeType: projectedName,
					code: projected.code,
					size: 4,
					alignment: 4,
					structure: false,
					handle: true,
					ownedValueHandle: ownedValueHandle,
					opaquePointer: false,
					nullable: false,
					owned: false
				};
			case IntegerValue(_, _) | EnumerationValue(_, _, _) | Boolean32Value | FloatValue(_):
				var size = structSize(projected.code);
				if (size == 0)
					throw "HXI output parameter has an unsupported scalar type";
				{
					haxeType: projected.haxeType,
					rawHaxeType: projected.haxeType,
					code: projected.code,
					size: size,
					alignment: size,
					structure: false,
					handle: false,
					ownedValueHandle: false,
					opaquePointer: false,
					nullable: false,
					owned: false
				};
			case PointerValue(_, nullable, opaquePointee, _) if (opaquePointee != null):
				var owned = switch parameter.ownership {
					case Owned(_): true;
					case Borrowed: false;
					case Unspecified: throw 'Opaque pointer output parameter "${parameter.name}" requires an ownership contract';
				}, typeName = owned ? ownedTypeName(opaquePointee, profile) : projectedTypeName(opaquePointee, profile);
				{
					haxeType: nullable ? 'Null<$typeName>' : typeName,
					rawHaxeType: nullable ? 'Null<${projectedTypeName(opaquePointee, profile)}>' : projectedTypeName(opaquePointee, profile),
					code: 11,
					size: Std.int(abi.pointerBits / 8),
					alignment: Std.int(abi.pointerBits / 8),
					structure: false,
					handle: false,
					ownedValueHandle: false,
					opaquePointer: true,
					nullable: nullable,
					owned: owned
				};
			case _: throw "HXI output parameters currently support scalar, fixed-structure, and typed opaque-pointer pointees";
		};
	}

	static function pointerFreeOutput(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>):Bool {
		var pointee = switch type {
			case Pointer(value): value;
			case _: return false;
		};
		return pointerFreeValue(pointee, declarations, []);
	}

	static function fixedStructureLayout(name:String, declarations:Map<String, HxiDeclaration>):Null<{size:Int, alignment:Int}> {
		return switch declarations.get(name) {
			case Structure(_, size, alignment, _, _): {size: size, alignment: alignment};
			case Alias(_, target, _): switch target {
					case Named(alias): fixedStructureLayout(alias, declarations);
					default: null;
				};
			case _: null;
		};
	}

	static function pointerFreeValue(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, visiting:Map<String, Bool>):Bool {
		return switch type {
			case Const(element) | Nullable(element): pointerFreeValue(element, declarations, visiting);
			case Array(element, _): pointerFreeValue(element, declarations, visiting);
			case Pointer(_): false;
			case Primitive(name): name != "utf8" && name != "void" && name != "c_void";
			case Named(name):
				if (visiting.exists(name)) false; else {
					visiting.set(name, true);
					var result = switch declarations.get(name) {
						case Alias(_, target, _): pointerFreeValue(target, declarations, visiting);
						case Structure(_, _, _, fields, _): {
								var result = true;
								for (field in fields)
									if (!pointerFreeValue(field.type, declarations, visiting))
										result = false;
								result;
							}
						case Handle(_, _, _, _) | Enumeration(_, _, _, _, _): true;
						case _: false;
					};
					visiting.remove(name);
					result;
				}
		};
	}

	static function emitOwnedHandleResultWrapper(output:StringBuf, publicName:String, rawName:String, argumentTypes:Array<String>, ownedType:String,
			documentation:Null<HxiDocumentation>):Void {
		var arguments = [for (index in 0...argumentTypes.length) 'arg$index:${argumentTypes[index]}'],
			callArguments = [for (index in 0...argumentTypes.length) 'arg$index'];
		emitDocumentationValue(output, documentation);
		output.add('function $publicName(${arguments.join(", ")}):$ownedType return $ownedType.adopt($rawName(${callArguments.join(", ")}));\n');
	}

	static function emitAggregateResultWrapper(output:StringBuf, publicName:String, rawName:String, argumentTypes:Array<String>, structureType:String,
			documentation:Null<HxiDocumentation>):Void {
		var arguments = [for (index in 0...argumentTypes.length) 'arg$index:${argumentTypes[index]}'],
			callArguments = [for (index in 0...argumentTypes.length) 'arg$index'];
		emitDocumentationValue(output, documentation);
		output.add('function $publicName(${arguments.join(", ")}):$structureType return $structureType.__hxi_attach($rawName(${callArguments.join(", ")}));\n');
	}

	static function emitOutputWrapper(output:StringBuf, nativeName:String, publicName:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>,
			rawArgumentTypes:Array<String>, resultType:String, abi:HxiAbi, profile:HxiProjectionProfile, library:String, nativeSymbol:String,
			signature:String, pointerOwnedSlotHelper:String, documentation:Null<HxiDocumentation>, ?ownedHandleResult:String,
			?aggregateResultType:String):Void {
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
						if (utf8)
							setup.push('var __array_storage_${parameter.name} = __hxi_struct_alloc(${parameter.name}.length * ${Std.int(abi.pointerBits / 8)}); var __array_roots_${parameter.name}:Array<haxe.io.Bytes> = []; for (__root in 0...(${parameter.name}.length + 1)) __array_roots_${parameter.name}.push(null); __array_roots_${parameter.name}[0] = __array_storage_${parameter.name}; var __array_${parameter.name}:haxe.io.Bytes = __hxi_struct_with_roots(__array_storage_${parameter.name}, __array_roots_${parameter.name}); for (__index in 0...${parameter.name}.length) { var __text = __hxi_struct_utf8_copy(${parameter.name}[__index]); __array_roots_${parameter.name}[__index + 1] = __text; __hxi_struct_set_borrowed_bytes(__array_${parameter.name}, __index * ${Std.int(abi.pointerBits / 8)}, __text); }');
						else
							setup.push('var __array_${parameter.name} = $elementType.array(${parameter.name});');
						callArguments.push('__array_${parameter.name}');
					}
				case Out | InOut:
					var info = outputInfo(parameter, abi, profile),
						local = "__out_" + parameter.name;
					if (parameter.direction == InOut)
						arguments.push('${parameter.name}:${info.haxeType}');
					if (info.structure)
						setup.push('var $local:${info.haxeType} = ${parameter.direction == InOut ? parameter.name : "new " + info.haxeType + "()"};');
					else {
						setup.push('var $local = haxe.io.Bytes.alloc(${info.size});');
						if (parameter.direction == InOut) {
							var nativeValue = info.handle ? '${parameter.name}.rawValue()' : info.code == 15 ? '(${parameter.name} ? 1 : 0)' : parameter.name;
							setup.push('__hxi_struct_set${structAccess(info.code)}($local, 0, $nativeValue);');
						}
					}
					callArguments.push(local);
					var expression = if (info.opaquePointer) {
						if (info.owned) {
							if (parameter.handleDisposition == Owned)
								throw 'Owned value handle output parameter "${parameter.name}" cannot use pointer output storage';
							var release = switch parameter.ownership {
								case Owned(symbol): symbol;
								case Borrowed | Unspecified: "";
							};
							'$pointerOwnedSlotHelper($local, 0, "${escape(library)}", "${escape(nativeSymbol)}", "${escape(signature)}", "${escape(release)}", ${info.nullable})';
						} else
							'__hxi_struct_get_pointer($local, 0, ${info.nullable})';
					} else
						info.structure ? local : info.code == 15 ? '__hxi_struct_get${structAccess(info.code)}($local, 0) != 0' : '__hxi_struct_get${structAccess(info.code)}($local, 0)';
					if (info.handle) {
						expression = 'cast($expression, ${info.rawHaxeType})';
						if (info.ownedValueHandle)
							expression = '${info.haxeType}.adopt($expression)';
					} else if (info.opaquePointer)
						expression = 'cast($expression, ${info.haxeType})';
					values.push({
						name: parameter.name,
						type: info.haxeType,
						expression: expression
					});
				case OutArray(_):
					throw "Output arrays require their dedicated wrapper";
				case OutBuffer(_):
					throw "Output buffers require their dedicated wrapper";
			}
		}
		var managedResultType = aggregateResultType != null ? aggregateResultType : ownedHandleResult == null ? resultType : ownedHandleResult,
			direct = resultType == "Void" && values.length == 1,
			resultOnly = values.length == 0;
		var wrapperResult = direct ? values[0].type : resultOnly ? managedResultType : upperFirst(publicName) + "OutResult";
		if (!direct && !resultOnly) {
			output.add('class $wrapperResult {\n');
			var fields:Array<{name:String, type:String}> = [];
			if (resultType != "Void")
				fields.push({name: ownedHandleResult == null ? "status" : "result", type: managedResultType});
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
		if (ownedHandleResult != null)
			output.add('\tvar __managed_result = $ownedHandleResult.adopt(__status);\n');
		else if (aggregateResultType != null)
			output.add('\tvar __managed_result = $aggregateResultType.__hxi_attach(__status);\n');
		if (resultOnly) {
			if (resultType != "Void")
				output.add('\treturn ${ownedHandleResult == null && aggregateResultType == null ? "__status" : "__managed_result"};\n');
		} else if (direct)
			output.add('\treturn ${values[0].expression};\n');
		else {
			var resultValues:Array<String> = resultType == "Void" ? [] : [
				ownedHandleResult == null && aggregateResultType == null ? "__status" : "__managed_result"];
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
					var info = outputInfo(parameter, abi, profile);
					arguments.push('${parameter.name}:${info.haxeType}');
					callArguments.push(parameter.name);
				case Out:
				case OutArray(_):
					return;
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
						valueType = outputInfo(parameter, abi, profile).haxeType;
				case In | InArray(_) | OutArray(_) | OutBuffer(_):
			}
		return resultType == "Void" && count == 1 ? valueType : count == 0 ? resultType : upperFirst(name) + "OutResult";
	}

	public static function byteArrayParameter(parameters:Array<compiler.ffi.HxiModel.HxiParameter>):Null<Int> {
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

	static function emitOutputArrayWrapper(output:StringBuf, nativeName:String, publicName:String, parameters:Array<compiler.ffi.HxiModel.HxiParameter>,
			rawArgumentTypes:Array<String>, resultType:String, array:{
			name:String,
			countParameter:String
		}, abi:HxiAbi, profile:HxiProjectionProfile,
			documentation:Null<HxiDocumentation>):Void {
		var arguments:Array<String> = [],
			queryArguments:Array<String> = [],
			fillArguments:Array<String> = [];
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			switch parameter.direction {
				case In:
					arguments.push('${parameter.name}:${rawArgumentTypes[index]}');
					queryArguments.push(parameter.name);
					fillArguments.push(parameter.name);
				case OutArray(_):
					queryArguments.push("null");
					fillArguments.push('__out_${array.name}');
				case InOut if (parameter.name == array.countParameter):
					queryArguments.push("__out_count");
					fillArguments.push("__out_count");
				case _:
					throw 'Unsupported parameter direction in output-array wrapper for "$nativeName"';
			}
		}
		var direct = resultType == "Void",
			wrapperResult = direct ? outputArrayType() : upperFirst(publicName) + "OutResult",
			pointerSize = Std.int(abi.pointerBits / 8);
		if (!direct) {
			output.add('class $wrapperResult {\n');
			output.add('\tpublic var status:$resultType;\n');
			output.add('\tpublic var ${array.name}:${outputArrayType()};\n');
			output.add('\tpublic function new(status:$resultType, ${array.name}:${outputArrayType()}) { this.status = status; this.${array.name} = ${array.name}; }\n');
			output.add('}\n');
		}
		emitDocumentationValue(output, documentation);
		output.add('function $publicName(${arguments.join(", ")}):$wrapperResult {\n');
		output.add('\tvar __out_count = haxe.io.Bytes.alloc(4);\n');
		output.add('\t__hxi_struct_setI32(__out_count, 0, 0);\n');
		output.add('\t__hxi_raw_$nativeName(${queryArguments.join(", ")});\n');
		output.add('\tvar __capacity = __hxi_struct_getI32(__out_count, 0);\n');
		output.add('\tif (__capacity < 0 || __capacity > ${Std.int(268435456 / pointerSize)}) throw "HXI output array count exceeds the safety limit";\n');
		output.add('\tvar __out_${array.name}:Null<haxe.io.Bytes> = __capacity == 0 ? null : haxe.io.Bytes.alloc(__capacity * $pointerSize);\n');
		output.add('\tif (__out_${array.name} != null) for (__byte in 0...__out_${array.name}.length) __out_${array.name}.set(__byte, 0);\n');
		output.add('\t__hxi_struct_setI32(__out_count, 0, __capacity);\n');
		if (direct)
			output.add('\t__hxi_raw_$nativeName(${fillArguments.join(", ")});\n');
		else
			output.add('\tvar __status = __hxi_raw_$nativeName(${fillArguments.join(", ")});\n');
		output.add('\tvar __length = __hxi_struct_getI32(__out_count, 0);\n');
		output.add('\tif (__length < 0 || __length > __capacity) throw "HXI output array wrote an invalid count";\n');
		output.add('\tvar __items:${outputArrayType()} = [];\n');
		output.add('\tfor (__index in 0...__length) __items.push(__hxi_struct_get_utf8(__out_${array.name}, __index * $pointerSize, true));\n');
		output.add(direct ? '\treturn __items;\n' : '\treturn new $wrapperResult(__status, __items);\n');
		output.add('}\n');
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
				case OutArray(_):
					throw "Output arrays cannot be combined with output buffers";
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

	public static function upperFirst(value:String):String
		return value.length == 0 ? value : value.charAt(0).toUpperCase() + value.substr(1);

	static function lowerFirst(value:String):String
		return value.length == 0 ? value : value.charAt(0).toLowerCase() + value.substr(1);

	public static function projectedFunctionName(value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.functionNames.get(value);
		if (mapped != null)
			return mapped;
		var stripped = stripPrefix(value, profile.functionPrefix);
		return profile.functionCase == "camel" ? camelCase(stripped) : value;
	}

	public static function projectedConstantName(value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.constantNames.get(value);
		if (mapped != null)
			return mapped;
		var stripped = stripPrefix(value, profile.constantPrefix);
		return profile.constantCase == "camel" ? camelCase(stripped) : value;
	}

	public static function projectedFieldName(typeName:String, value:String, profile:Null<HxiProjectionProfile>):String {
		if (profile == null)
			return value;
		var mapped = profile.fieldNames.get(typeName + "." + value);
		return mapped == null ? profile.fieldCase == "camel" ? camelCase(value) : value : mapped;
	}

	static function stripPrefix(value:String, prefix:Null<String>):String
		return prefix != null && StringTools.startsWith(value, prefix) ? value.substr(prefix.length) : value;

	public static function enumTypeName(value:String, ?profile:HxiProjectionProfile):String {
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

	public static function projectedTypeName(value:String, profile:Null<HxiProjectionProfile>):String {
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

	public static function ownedTypeName(value:String, profile:Null<HxiProjectionProfile>):String {
		var projected = projectedTypeName(value, profile),
			separator = projected.lastIndexOf(".");
		return (separator < 0 ? "" : projected.substr(0, separator + 1)) + "Owned" + projected.substr(separator + 1);
	}

	public static function enumValuePrefix(values:Array<HxiEnumValue>, ?profile:HxiProjectionProfile):Array<String> {
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

	public static function enumValueName(value:String, prefix:Array<String>, ?enumName:String, ?profile:HxiProjectionProfile):String {
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

	public static function project(value:HxiAbiValue, allowVoid:Bool, ?profile:HxiProjectionProfile):Null<{
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
			case Boolean32Value: {
					haxeType: "Bool",
					code: 15,
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

	static function parameterIndex(parameters:Array<HxiParameter>, name:String):Int {
		for (index in 0...parameters.length)
			if (parameters[index].name == name)
				return index;
		throw 'Unknown HXI argument length parameter "$name"';
	}

	static function isConstPointer(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Pointer(element): switch element {
					case Const(value): true;
					default: false;
				};
			case Const(element): isConstPointer(element);
			case _: false;
		};

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
			case Boolean32Value: "6";
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
					if (fieldOffset(field) != cursor)
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

	static function abiLayout(type:compiler.ffi.HxiModel.HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):{size:Int, align:Int} {
		var layout = abi.layout(type);
		if (layout == null)
			throw 'HXI type $type has no fixed ABI layout';
		return {size: layout.size, align: layout.align};
	}

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
			case 15: "I32";
			case 7 | 8: "I64";
			case 9: "F32";
			case 10: "F64";
			case _: null;
		};

	static function structSize(code:Int):Int
		return switch code {
			case 1 | 2: 1;
			case 3 | 4: 2;
			case 5 | 6 | 9 | 15: 4;
			case 7 | 8 | 10: 8;
			case _: 0;
		};

	static function structAccessHaxeType(access:String):String
		return switch access {
			case "I64": "haxe.Int64";
			case "F32" | "F64": "Float";
			case _: "Int";
		};

	static function isHandleAbi(value:HxiAbiValue):Bool
		return switch value {
			case HandleValue(_): true;
			case _: false;
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

	static inline function utf8PointerArray(type:compiler.ffi.HxiModel.HxiType):Bool
		return utf8ArrayPointer(type);

	static function utf8ArrayElement(type:compiler.ffi.HxiModel.HxiType):Bool
		return switch type {
			case Const(element): utf8ArrayElement(element);
			case Primitive("utf8"): true;
			case _: false;
		};

	static function irType(code:Int, result:Bool = false, nativeAbstract:Null<String> = null):IrType
		return switch code {
			case 0: Void;
			case 15: Bool;
			case 7 | 8: I64;
			case 9 | 10: F64;
			case 11: result ? Abstract("native_pointer") : nativeAbstract == null ? ManagedBytes : Abstract(nativeAbstract);
			case 12: ManagedBytes;
			case 13: Bytes;
			default: I32;
		};
}
