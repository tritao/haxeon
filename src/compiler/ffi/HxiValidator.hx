package compiler.ffi;

import haxe.Int64;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiHandleDisposition;
import compiler.ffi.HxiAbi.HxiAbiValue;

/** Performs semantic checks over raw HXI models and their visible dependency declarations. */
class HxiValidator {
	static function pointerLike(type:HxiType):Bool
		return switch type {
			case Pointer(_): true;
			case Primitive("utf8"): true;
			case Nullable(element) | Const(element): pointerLike(element);
			case _: false;
		};

	/** Resolves declared interfaces and validates one model against their visible declarations. */
	public static function validateComposition(value:HxiInterface, dependencies:Array<HxiInterface>):Void {
		var byName:Map<String, HxiInterface> = [],
			visible:Array<HxiDeclaration> = [];
		for (dependency in dependencies) {
			if (byName.exists(dependency.name))
				fail('Duplicate HXI dependency interface "${dependency.name}"', dependency.span);
			byName.set(dependency.name, dependency);
		}
		for (name in value.dependencies) {
			var dependency = byName.get(name);
			if (dependency == null)
				fail('FFI interface "${value.name}" depends on unknown interface "$name"', value.span);
			for (declaration in dependency.declarations)
				visible.push(declaration);
		}
		validate(value, visible);
	}

	static function validateParameterMetadata(parameter:HxiParameter, callback:Bool):Void {
		var metadata = parameter.metadata,
			outputDirections = ["out", "inout", "out_buffer", "in_array", "out_array"],
			outputCount = 0;
		for (name in outputDirections)
			if (metadata.exists(name))
				outputCount++;
		if (outputCount > 1)
			fail('Parameter "${parameter.name}" cannot combine output direction metadata', parameter.span);
		if (metadata.exists("borrowed") && metadata.exists("owned"))
			fail('Parameter "${parameter.name}" cannot combine @borrowed and @owned', parameter.span);
		validateOwnershipMetadata(metadata, 'Parameter "${parameter.name}"', parameter.span);
		if (callback && (outputCount > 0 || metadata.exists("borrowed") || metadata.exists("owned")))
			fail('Callback parameter "${parameter.name}" cannot use output direction metadata', parameter.span);
		if (callback && metadata.exists("retained"))
			fail('Callback parameter "${parameter.name}" cannot use @retained', parameter.span);
		if ((metadata.exists("borrowed") || metadata.exists("owned")) && parameter.direction != Out)
			fail('Parameter "${parameter.name}" can use @borrowed or @owned only with @out', parameter.span);
	}

	static function validateOwnershipMetadata(metadata:Map<String, Array<String>>, owner:String, span:SourceSpan):Void {
		var borrowed = metadata.get("borrowed"), owned = metadata.get("owned");
		if (borrowed != null && borrowed.length != 0)
			fail('@borrowed on $owner does not accept values', span);
		if (owned != null
			&& owned.length > 0
			&& (owned.length != 1
				|| !StringTools.startsWith(owned[0], '"')
				|| !StringTools.endsWith(owned[0], '"')
				|| owned[0].length <= 2))
			fail('@owned on $owner accepts no value for a value handle or one non-empty string release symbol for an opaque pointer', span);
	}

	static function validateArrayLengths(declarations:Array<HxiDeclaration>):Void {
		for (declaration in declarations)
			switch declaration {
				case Alias(_, type, span) | Handle(_, type, _, span) | Enumeration(_, type, _, _, span):
					validateArrayLength(type, span);
				case Structure(_, _, _, fields, _):
					for (field in fields)
						validateArrayLength(field.type, field.span);
				case Callback(_, parameters, result, _, span):
					for (parameter in parameters)
						validateArrayLength(parameter.type, parameter.span);
					validateArrayLength(result, span);
				case Function(_, parameters, result, _, _, _, _, span):
					for (parameter in parameters)
						validateArrayLength(parameter.type, parameter.span);
					validateArrayLength(result, span);
				case _:
			}
	}

	static function validateArrayLength(type:HxiType, span:SourceSpan):Void
		switch type {
			case Array(element, length):
				if (length <= 0)
					fail("Array length must be positive", span);
				validateArrayLength(element, span);
			case Pointer(element) | Nullable(element) | Const(element):
				validateArrayLength(element, span);
			case _:
		}

	public static function validate(value:HxiInterface, visible:Array<HxiDeclaration>):Void {
		var names:Map<String, SourceSpan> = [],
			declarationsByName:Map<String, HxiDeclaration> = [],
			visibleNames:Map<String, Bool> = [];
		for (declaration in visible) {
			var visibleName = declarationName(declaration);
			if (names.exists(visibleName.name))
				fail('Duplicate visible HXI declaration "${visibleName.name}"', visibleName.span);
			names.set(visibleName.name, visibleName.span);
			declarationsByName.set(visibleName.name, declaration);
			visibleNames.set(visibleName.name, true);
		}
		for (declaration in value.declarations) {
			var named = declarationName(declaration);
			if (names.exists(named.name) && !visibleNames.exists(named.name))
				fail('Duplicate HXI declaration "${named.name}"', named.span);
			names.set(named.name, named.span);
			declarationsByName.set(named.name, declaration);
		}
		validateArrayLengths(value.declarations);
		validateAliasCycles(value.declarations);
		var abi = HxiAbi.forInterface(value, declarationsByName);
		for (declaration in value.declarations)
			switch declaration {
				case Opaque(_, _) | Constant(_, _, _):
				case Alias(_, type, span):
					validateType(type, names, declarationsByName, span, false);
				case Handle(name, representation, destroySymbol, span):
					validateType(representation, names, declarationsByName, span, false);
					switch abi.classify(representation) {
						case IntegerValue(32, Unsigned):
						case _: fail('Handle "$name" requires an unsigned 32-bit representation', span);
					}
					if (destroySymbol != null)
						validateValueHandleDestroy(value, name, destroySymbol, declarationsByName, abi, span);
				case Structure(name, size, align, fields, span):
					if (size <= 0 || align <= 0 || (align & (align - 1)) != 0 || size % align != 0)
						fail('Struct "$name" has invalid layout', span);
					var fieldNames:Map<String, Bool> = [];
					var structSizeFields = 0;
					var ranges:Array<{start:Int, end:Int, name:String}> = [];
					for (field in fields) {
						validateOwnershipMetadata(field.metadata, 'field "${field.name}"', field.span);
						if (field.metadata.exists("borrowed") && field.metadata.exists("owned"))
							fail('Field "${field.name}" cannot combine @borrowed and @owned', field.span);
						if (fieldNames.exists(field.name))
							fail('Duplicate field "${field.name}" in struct "$name"', field.span);
						fieldNames.set(field.name, true);
						if (field.structSize) {
							structSizeFields++;
							switch abi.classify(field.type) {
								case IntegerValue(32, Unsigned):
								case _: fail('@struct_size field "${field.name}" in struct "$name" must use an unsigned 32-bit integer', field.span);
							}
							if (field.offset != 0)
								fail('@struct_size field "${field.name}" in struct "$name" must be at offset zero', field.span);
						}
						var layout = abi.layout(field.type);
						if (layout == null)
							fail('Field "${field.name}" in struct "$name" has no fixed C layout', field.span);
						if (field.offset == null || field.offset < 0 || layout.align > align || field.offset % layout.align != 0
							|| field.offset > size - layout.size)
							fail('Field "${field.name}" has an invalid offset for struct "$name"', field.span);
						for (range in ranges)
							if (field.offset < range.end && field.offset + layout.size > range.start)
								fail('Field "${field.name}" overlaps field "${range.name}" in struct "$name"', field.span);
						ranges.push({start: field.offset, end: field.offset + layout.size, name: field.name});
						validateType(field.type, names, declarationsByName, field.span, false);
						if (field.lengthField != null) {
							if (field.ownership != Borrowed
								|| (!bytePointerLike(field.type, declarationsByName)
									&& structurePointerType(field.type, declarationsByName) == null
									&& !utf8ArrayPointer(field.type)))
								fail('@length_field on "${field.name}" requires a borrowed byte, void, or structure pointer', field.span);
							var length = Lambda.find(fields, candidate -> candidate.name == field.lengthField);
							if (length == null)
								fail('@length_field on "${field.name}" references missing field "${field.lengthField}"', field.span);
							switch abi.classify(length.type) {
								case IntegerValue(32 | 64, Unsigned):
								case _:
									fail('@length_field on "${field.name}" requires an unsigned 32- or 64-bit length field', length.span);
							}
						}
						switch field.ownership {
							case Owned(_): fail('Owned pointer field "${field.name}" is not supported; keep ownership in a separate handle', field.span);
							case Borrowed:
								if (field.lengthField == null
									&& !opaquePointerLike(field.type,
										declarationsByName)) fail('@borrowed field "${field.name}" requires a pointer to an opaque type', field.span);
							case Unspecified:
						}
						if (field.handleDisposition == Owned)
							fail('Owned value handle field "${field.name}" is not supported; keep ownership in a separate handle', field.span);
					}
					if (structSizeFields > 1)
						fail('Struct "$name" cannot declare more than one @struct_size field', span);
				case Enumeration(name, representation, flags, values, span):
					validateType(representation, names, declarationsByName, span, false);
					var integer = switch abi.classify(representation) {
						case IntegerValue(bits, sign) if ((!flags && bits <= 32) || (flags && bits <= 64 && sign == Unsigned)):
							{bits: bits, signed: sign == Signed};
						case _:
							fail(flags ? 'Flags "$name" require an unsigned 8/16/32/64-bit integer representation' : 'Enum "$name" requires an 8/16/32-bit integer representation',
								span);
					};
					var valueNames:Map<String, Bool> = [],
						seenValues:Map<String, String> = [];
					for (entry in values) {
						if (valueNames.exists(entry.name))
							fail('Duplicate value "${entry.name}" in enum "$name"', entry.span);
						valueNames.set(entry.name, true);
						if (!flags && integer.bits < 32) {
							var minimum = integer.signed ? -(1 << (integer.bits - 1)) : 0;
							var maximum = integer.signed ? (1 << (integer.bits - 1)) - 1 : (1 << integer.bits) - 1;
							if (Int64.compare(entry.value, Int64.ofInt(minimum)) < 0
								|| Int64.compare(entry.value, Int64.ofInt(maximum)) > 0)
								fail('Value "${entry.name}" is outside the representation of enum "$name"', entry.span);
						}
						var key = Int64.toStr(entry.value);
						if (seenValues.exists(key))
							fail('Value "${entry.name}" duplicates "${seenValues.get(key)}" in enum "$name"', entry.span);
						seenValues.set(key, entry.name);
					}
					if (flags) {
						var knownBits = Int64.ofInt(0),
							zero = Int64.ofInt(0),
							one = Int64.ofInt(1),
							mask = integer.bits == 64 ? Int64.ofInt(-1) : Int64.sub(Int64.shl(one, integer.bits), one);
						for (entry in values) {
							var minimum = integer.bits == 32 ? Int64.parseString("-2147483648") : zero,
								maximum = integer.bits == 64 ? Int64.parseString("9223372036854775807") : Int64.sub(Int64.shl(one, integer.bits), one);
							if (integer.bits != 64 && (Int64.compare(entry.value, minimum) < 0 || Int64.compare(entry.value, maximum) > 0))
								fail('Flag value "${entry.name}" is outside the representation of flags "$name"', entry.span);
							var value = Int64.and(entry.value, mask);
							if (Int64.compare(value, zero) != 0 && Int64.compare(Int64.and(value, Int64.sub(value, one)), zero) == 0)
								knownBits = Int64.or(knownBits, value);
						}
						for (entry in values) {
							var value = Int64.and(entry.value, mask);
							if (Int64.compare(Int64.and(value, Int64.xor(knownBits, Int64.ofInt(-1))), zero) != 0)
								fail('Flag value "${entry.name}" contains bits not declared by a single-bit flag in "$name"', entry.span);
						}
					}
				case Callback(name, parameters, result, callConvention, span):
					validateCallConvention(name, callConvention, abi, span);
					if (parameters.length > 16)
						fail('Callback "$name" exceeds the 16 argument limit', span);
					for (parameter in parameters) {
						validateParameterMetadata(parameter, true);
						validateCallbackType(parameter.type, abi, parameter.span, false);
					}
					validateCallbackType(result, abi, span, true);
				case Function(name, parameters, result, _, _, callConvention, resultPolicy, span):
					validateCallConvention(name, callConvention, abi, span);
					validateOwnershipMetadata(resultPolicy.metadata, 'result of function "$name"', span);
					if (resultPolicy.metadata.exists("borrowed") && resultPolicy.metadata.exists("owned"))
						fail('Function "$name" cannot combine @borrowed and @owned', span);
					var outputBuffer:Null<{name:String, sizeParameter:String, span:SourceSpan}> = null,
						outputArray:Null<{name:String, countParameter:String, span:SourceSpan}> = null;
					for (parameter in parameters) {
						validateParameterMetadata(parameter, false);
						validateType(parameter.type, names, declarationsByName, parameter.span, false);
						if (parameter.retained)
							switch abi.classify(parameter.type) {
								case CallbackValue(_, _, _, _):
								case _: fail('Parameter "${parameter.name}" can use @retained only with a callback type', parameter.span);
							}
						switch parameter.direction {
							case OutBuffer(sizeParameter):
								if (outputBuffer != null)
									fail('Function "$name" cannot declare more than one output buffer', parameter.span);
								if (!bytePointerLike(parameter.type, declarationsByName))
									fail('Output buffer "${parameter.name}" requires a byte pointer', parameter.span);
								if (!nullablePointer(parameter.type))
									fail('Output buffer "${parameter.name}" must be nullable for its size query', parameter.span);
								outputBuffer = {name: parameter.name, sizeParameter: sizeParameter, span: parameter.span};
							case OutArray(countParameter):
								if (outputArray != null)
									fail('Function "$name" cannot declare more than one output array', parameter.span);
								if (!nullablePointer(parameter.type) || !utf8ArrayPointer(parameter.type))
									fail('Output array "${parameter.name}" requires a nullable pointer to a UTF-8 pointer array', parameter.span);
								outputArray = {name: parameter.name, countParameter: countParameter, span: parameter.span};
							case Out | InOut:
								if (!pointerLike(parameter.type))
									fail('Output parameter "${parameter.name}" requires a pointer type', parameter.span);
								if (switch parameter.type {
										case Nullable(_): true;
										case _: false;
									})
									fail('Output parameter "${parameter.name}" cannot be nullable', parameter.span);
								validateOutputType(parameter.name, parameter.type, parameter.ownership, parameter.handleDisposition, abi, declarationsByName,
									parameter.span);
							case InArray(countParameter):
								if (structurePointerType(parameter.type, declarationsByName) == null
									&& !utf8ArrayPointer(parameter.type)
									&& !bytePointerLike(parameter.type, declarationsByName))
									fail('Input array "${parameter.name}" requires a byte, structure, or UTF-8 pointer array', parameter.span);
								var count = Lambda.find(parameters, candidate -> candidate.name == countParameter);
								if (count == null)
									fail('Input array "${parameter.name}" references missing count parameter "$countParameter"', parameter.span);
								switch abi.classify(count.type) {
									case IntegerValue(32, Unsigned):
									case _: fail('Input array "${parameter.name}" requires an unsigned 32-bit count parameter', count.span);
								}
							case In:
						}
					}
					if (outputArray != null)
						validateOutputArray(name, outputArray, parameters, abi, span);
					if (outputBuffer != null)
						validateOutputBuffer(name, outputBuffer, parameters, abi, span);
					if (outputArray != null && outputBuffer != null)
						fail('Function "$name" cannot combine an output array with an output buffer', span);
					validateType(result, names, declarationsByName, span, true);
					switch abi.classify(result, true) {
						case CallbackValue(_, _, _, _): fail('Function "$name" cannot return a callback handle yet', span);
						case _:
					}
					if (resultPolicy.length != null && !bytePointerLike(result, declarationsByName))
						fail('@length on "$name" requires a pointer to byte-sized data or void', span);
			}
		validatePointerResultContracts(value, declarationsByName, abi);
	}

	static function validatePointerResultContracts(value:HxiInterface, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):Void {
		for (declaration in value.declarations)
			switch declaration {
				case Function(name, parameters, result, _, _, callConvention, resultPolicy, span):
					switch resultPolicy.ownership {
						case Owned(releaseSymbol):
							switch abi.classify(result, true) {
								case HandleValue(_): fail('@owned("release_symbol") on value handle result "$name" is invalid; use bare @owned and declare @destroy on the handle',
										span);
								case _: validateReleaseFunction(value, name, result, releaseSymbol, declarations, span);
							}
						case Borrowed:
							switch abi.classify(result, true) {
								case PointerValue(_, _, _, _) | Utf8Value(_):
								case HandleValue(_):
								case _: fail('@borrowed on "$name" requires a pointer return type or value handle', span);
							}
						case Unspecified:
					}
					if (resultPolicy.handleDisposition == Owned)
						validateOwnedValueHandle(name, result, declarations, abi, span);
					for (parameter in parameters)
						switch parameter.ownership {
							case Owned(releaseSymbol):
								var outputValue = pointerPointee(parameter.type, declarations);
								if (outputValue == null)
									fail('Owned output parameter "${parameter.name}" must point to a typed opaque pointer', parameter.span);
								validateReleaseFunction(value, '$name.${parameter.name}', outputValue, releaseSymbol, declarations, parameter.span);
							case Borrowed | Unspecified:
						}
					for (parameter in parameters)
						if (parameter.handleDisposition == Owned) {
							var outputValue = pointerPointee(parameter.type, declarations);
							if (outputValue == null)
								fail('Owned output parameter "${parameter.name}" must point to a typed value handle', parameter.span);
							validateOwnedValueHandle('$name.${parameter.name}', outputValue, declarations, abi, parameter.span);
						}
					if (resultPolicy.length != null)
						validateLengthFunction(value, name, parameters, callConvention, resultPolicy.length, declarations, abi, span);
				case _:
			}
	}

	static function validateReleaseFunction(value:HxiInterface, owner:String, result:HxiType, releaseSymbol:String, declarations:Map<String, HxiDeclaration>,
			span:SourceSpan):Void {
		var release = referencedFunction(value, owner, "release", releaseSymbol, span);
		switch release {
			case Function(releaseName, parameters, releaseResult, _, _, callConvention, _, releaseSpan):
				var resultPointee = pointerPointee(result, declarations),
					releasePointee = parameters.length == 1 ? pointerPointee(parameters[0].type, declarations) : null,
					returnsVoid = switch releaseResult {
						case Primitive("void"): true;
						case _: false;
					},
					matchesPointee = resultPointee != null
						&& releasePointee != null
						&& (canonicalTypeKey(releasePointee, declarations) == canonicalTypeKey(Primitive("void"), declarations)
							|| canonicalTypeKey(resultPointee, declarations) == canonicalTypeKey(releasePointee, declarations));
				if (callConvention != "cdecl" || parameters.length != 1 || parameters[0].direction != In || !matchesPointee || !returnsVoid)
					fail('Release function "$releaseName" for owned result "$owner" must be cdecl, accept one compatible input pointer, and return void',
						releaseSpan);
			case _:
				fail('Internal error resolving release symbol "$releaseSymbol"', span);
		}
	}

	static function validateLengthFunction(value:HxiInterface, owner:String, parameters:Array<HxiParameter>, callConvention:String, lengthSymbol:String,
			declarations:Map<String, HxiDeclaration>, abi:HxiAbi, span:SourceSpan):Void {
		var length = referencedFunction(value, owner, "length", lengthSymbol, span);
		switch length {
			case Function(lengthName, lengthParameters, lengthResult, _, _, lengthCallConvention, _, lengthSpan):
				if (lengthCallConvention != callConvention)
					fail('Length function "$lengthName" for "$owner" must use calling convention "$callConvention"', lengthSpan);
				if (lengthParameters.length != parameters.length)
					fail('Length function "$lengthName" for "$owner" must accept the same arguments', lengthSpan);
				for (index in 0...parameters.length)
					if (canonicalTypeKey(parameters[index].type, declarations) != canonicalTypeKey(lengthParameters[index].type, declarations))
						fail('Argument ${index + 1} of length function "$lengthName" for "$owner" must match the pointer function ABI type',
							lengthParameters[index].span);
				switch abi.classify(lengthResult, true) {
					case IntegerValue(bits, Unsigned) if (bits == abi.pointerBits):
					case _: fail('Length function "$lengthName" for "$owner" must return target-sized unsigned size_t', lengthSpan);
				}
			case _:
				fail('Internal error resolving length symbol "$lengthSymbol"', span);
		}
	}

	static function referencedFunction(value:HxiInterface, owner:String, role:String, symbol:String, span:SourceSpan):HxiDeclaration {
		if (symbol.length == 0)
			fail('@$role on "$owner" requires a non-empty native function symbol', span);
		var found:Null<HxiDeclaration> = null;
		for (declaration in value.declarations)
			switch declaration {
				case Function(name, _, _, declaredSymbol, _, _, _, _) if ((declaredSymbol == null ? name : declaredSymbol) == symbol):
					if (found != null)
						fail('Native $role symbol "$symbol" referenced by "$owner" is ambiguous in interface "${value.name}"', span);
					found = declaration;
				case _:
			}
		if (found == null)
			fail('Native $role symbol "$symbol" referenced by "$owner" must name a function declared in interface "${value.name}"', span);
		return found;
	}

	static function pointerPointee(type:HxiType, declarations:Map<String, HxiDeclaration>):Null<HxiType>
		return switch type {
			case Const(element) | Nullable(element): pointerPointee(element, declarations);
			case Pointer(element): element;
			case Primitive("utf8"): Primitive("c_char");
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): pointerPointee(target, declarations);
					case _: null;
				}
			case _: null;
		};

	static function canonicalTypeKey(type:HxiType, declarations:Map<String, HxiDeclaration>):String
		return switch type {
			case Primitive(name): 'primitive:$name';
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): canonicalTypeKey(target, declarations);
					case _: 'named:$name';
				}
			case Pointer(element): 'pointer<${canonicalTypeKey(element, declarations)}>';
			case Nullable(element): 'nullable<${canonicalTypeKey(element, declarations)}>';
			case Const(element): 'const<${canonicalTypeKey(element, declarations)}>';
			case Array(element, length): 'array<${canonicalTypeKey(element, declarations)},$length>';
		};

	static function validateOutputType(name:String, type:HxiType, ownership:HxiOwnership, handleDisposition:HxiHandleDisposition, abi:HxiAbi,
			declarations:Map<String, HxiDeclaration>, span:SourceSpan):Void {
		var pointee = switch type {
			case Pointer(value):
				switch value {
					case Const(_): fail('Output parameter "$name" cannot point to const data', span);
					case _: value;
				}
			case _: return;
		};
		var classified = try abi.classify(pointee) catch (error:Dynamic) {
			fail(Std.string(error), span);
			VoidValue;
		};
		switch classified {
			case HandleValue(handleName):
				switch ownership {
					case Unspecified | Borrowed:
					case Owned(_): fail('Owned value handle output parameter "$name" uses @owned without arguments; its handle declares @destroy', span);
				}
				if (handleDisposition == Owned)
					requireValueHandleDestroy(name, handleName, declarations, span);
			case IntegerValue(_, _) | EnumerationValue(_, _, _) | Boolean32Value | FloatValue(_) | AggregateValue(_, _, _):
				if (ownership != Unspecified || handleDisposition != Unspecified)
					fail('Output parameter "$name" ownership metadata requires a pointer to an opaque handle', span);
			case PointerValue(_, _, opaquePointee, _) if (opaquePointee != null):
				switch ownership {
					case Borrowed | Owned(_):
					case Unspecified: fail('Opaque pointer output parameter "$name" requires @borrowed or @owned("release_symbol")', span);
				}
				if (handleDisposition == Owned)
					fail('Owned opaque pointer output parameter "$name" requires @owned("release_symbol")', span);
			case _:
				fail('Output parameter "$name" currently requires a scalar, fixed-structure, or explicitly owned opaque-pointer pointee', span);
		}
	}

	static function validateOwnedValueHandle(owner:String, type:HxiType, declarations:Map<String, HxiDeclaration>, abi:HxiAbi, span:SourceSpan):Void {
		switch abi.classify(type) {
			case HandleValue(name):
				requireValueHandleDestroy(owner, name, declarations, span);
			case _:
				fail('@owned without a release symbol on "$owner" requires a typed value handle with @destroy', span);
		}
	}

	static function requireValueHandleDestroy(owner:String, handleName:String, declarations:Map<String, HxiDeclaration>, span:SourceSpan):String {
		return switch declarations.get(handleName) {
			case Handle(_, _, destroySymbol, _) if (destroySymbol != null): destroySymbol;
			case _: fail('Owned value handle "$owner" requires handle "$handleName" to declare @destroy("...")', span);
		};
	}

	static function validateValueHandleDestroy(value:HxiInterface, name:String, destroySymbol:String, declarations:Map<String, HxiDeclaration>, abi:HxiAbi,
			span:SourceSpan):Void {
		var destroy = referencedFunction(value, name, "destroy", destroySymbol, span);
		switch destroy {
			case Function(functionName, parameters, result, _, _, callConvention, _, functionSpan):
				var acceptsHandle = parameters.length == 1
					&& parameters[0].direction == In
					&& canonicalTypeKey(parameters[0].type, declarations) == canonicalTypeKey(Named(name), declarations),
					returnsSupported = switch abi.classify(result, true) {
						case VoidValue | IntegerValue(_, _) | EnumerationValue(_, _, _) | Boolean32Value: true;
						case _: false;
					};
				if (callConvention != "cdecl" || !acceptsHandle || !returnsSupported)
					fail('Destroy function "$functionName" for value handle "$name" must be cdecl, accept that handle by value, and return void or an integer/enum status',
						functionSpan);
			case _:
				fail('Internal error resolving destroy symbol "$destroySymbol"', span);
		}
	}

	static function validateOutputBuffer(functionName:String, buffer:{name:String, sizeParameter:String, span:SourceSpan}, parameters:Array<HxiParameter>,
			abi:HxiAbi, span:SourceSpan):Void {
		var size:HxiParameter = null;
		for (parameter in parameters)
			if (parameter.name == buffer.sizeParameter)
				size = parameter;
		if (size == null)
			fail('Output buffer "${buffer.name}" references missing size parameter "${buffer.sizeParameter}"', buffer.span);
		if (size.direction != InOut)
			fail('Output buffer size parameter "${size.name}" must use @inout', size.span);
		var pointee = switch size.type {
			case Pointer(value): value;
			case _: fail('Output buffer size parameter "${size.name}" must be ptr<u32>', size.span);
		};
		switch abi.classify(pointee) {
			case IntegerValue(32, Unsigned):
			case _:
				fail('Output buffer size parameter "${size.name}" must be ptr<u32>', size.span);
		}
		for (parameter in parameters)
			switch parameter.direction {
				case OutBuffer(_) | In:
				case InOut if (parameter.name == size.name):
				case _:
					fail('Function "$functionName" cannot mix an output buffer with unrelated output parameters', span);
			}
	}

	static function validateOutputArray(functionName:String, array:{name:String, countParameter:String, span:SourceSpan}, parameters:Array<HxiParameter>,
			abi:HxiAbi, span:SourceSpan):Void {
		var count = Lambda.find(parameters, parameter -> parameter.name == array.countParameter);
		if (count == null)
			fail('Output array "${array.name}" references missing count parameter "${array.countParameter}"', array.span);
		if (count.direction != InOut)
			fail('Output array count parameter "${count.name}" must use @inout', count.span);
		var pointee = switch count.type {
			case Pointer(value): value;
			case _: fail('Output array count parameter "${count.name}" must be ptr<u32>', count.span);
		};
		switch abi.classify(pointee) {
			case IntegerValue(32, Unsigned):
			case _:
				fail('Output array count parameter "${count.name}" must be ptr<u32>', count.span);
		}
		for (parameter in parameters)
			switch parameter.direction {
				case OutArray(_) | In:
				case InOut if (parameter.name == count.name):
				case _:
					fail('Function "$functionName" cannot mix an output array with unrelated directed parameters', span);
			}
	}

	static function nullablePointer(type:HxiType):Bool
		return switch type {
			case Nullable(inner):
				switch inner {
					case Pointer(_): true;
					case _: false;
				}
			case _: false;
		};

	static function validateCallConvention(name:String, convention:String, abi:HxiAbi, span:SourceSpan):Void {
		if (convention != "cdecl" && convention != "stdcall" && convention != "system")
			fail('Declaration "$name" has unsupported calling convention "$convention"', span);
		if (convention == "stdcall" && abi.target.indexOf("windows") < 0 && abi.target.indexOf("mingw") < 0 && abi.target.indexOf("msvc") < 0)
			fail('Calling convention "stdcall" is only available for Windows targets', span);
	}

	static function validateCallbackType(type:HxiType, abi:HxiAbi, span:SourceSpan, allowVoid:Bool):Void
		try {
			switch abi.classify(type, allowVoid) {
				case VoidValue if (allowVoid):
				case IntegerValue(_, _) | EnumerationValue(_, _, _) | HandleValue(_) | Boolean32Value | FloatValue(_) | AggregateValue(_, _, _) | Utf8Value(_):
				case PointerValue(_, _, _, _) if (!allowVoid):
				case _:
					fail("Callbacks support scalar, aggregate, and pointer arguments with scalar, aggregate, or void results", span);
			}
		} catch (error:Dynamic) {
			fail(Std.string(error), span);
		}

	static function validateAliasCycles(declarations:Array<HxiDeclaration>):Void {
		var aliases:Map<String, {type:HxiType, span:SourceSpan}> = [];
		for (declaration in declarations)
			switch declaration {
				case Alias(name, type, span):
					aliases.set(name, {type: type, span: span});
				case _:
			}
		var visiting:Map<String, Bool> = [], complete:Map<String, Bool> = [];
		for (name in aliases.keys())
			visitAlias(name, aliases, visiting, complete);
	}

	static function visitAlias(name:String, aliases:Map<String, {type:HxiType, span:SourceSpan}>, visiting:Map<String, Bool>, complete:Map<String, Bool>):Void {
		if (complete.exists(name))
			return;
		var alias = aliases.get(name);
		if (alias == null)
			return;
		if (visiting.exists(name))
			fail('Cyclic HXI type alias "$name"', alias.span);
		visiting.set(name, true);
		visitTypeAliases(alias.type, aliases, visiting, complete);
		visiting.remove(name);
		complete.set(name, true);
	}

	static function bytePointerLike(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Nullable(element) | Const(element): bytePointerLike(element, names);
			case Pointer(element): byteElement(element, names);
			case _: false;
		};

	static function structurePointerType(type:HxiType, names:Map<String, HxiDeclaration>):Null<String>
		return switch type {
			case Nullable(element) | Const(element): structurePointerType(element, names);
			case Pointer(element): structureElementType(element, names);
			case _: null;
		};

	static function structureElementType(type:HxiType, names:Map<String, HxiDeclaration>):Null<String>
		return switch type {
			case Const(element): structureElementType(element, names);
			case Named(name):
				switch names.get(name) {
					case Structure(_, _, _, _, _): name;
					case Alias(_, target, _): structureElementType(target, names);
					case _: null;
				}
			case _: null;
		};

	static function utf8ArrayPointer(type:HxiType):Bool
		return switch type {
			case Const(element) | Nullable(element): utf8ArrayPointer(element);
			case Pointer(element): utf8ArrayElement(element);
			case _: false;
		};

	static function utf8ArrayElement(type:HxiType):Bool
		return switch type {
			case Const(element): utf8ArrayElement(element);
			case Primitive("utf8"): true;
			case _: false;
		};

	static function opaquePointerLike(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Nullable(element) | Const(element): opaquePointerLike(element, names);
			case Pointer(element): opaqueElement(element, names);
			case _: false;
		};

	static function opaqueElement(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Const(element): opaqueElement(element, names);
			case Named(name):
				switch names.get(name) {
					case Opaque(_, _): true;
					case Alias(_, target, _): opaqueElement(target, names);
					case _: false;
				}
			case _: false;
		};

	static function byteElement(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Const(element): byteElement(element, names);
			case Primitive("void" | "i8" | "u8" | "c_char" | "c_schar" | "c_uchar"): true;
			case Named(name):
				switch names.get(name) {
					case Alias(_, target, _): byteElement(target, names);
					case _: false;
				}
			case _: false;
		};

	static function visitTypeAliases(type:HxiType, aliases:Map<String, {type:HxiType, span:SourceSpan}>, visiting:Map<String, Bool>,
			complete:Map<String, Bool>):Void
		switch type {
			case Named(name) if (aliases.exists(name)):
				visitAlias(name, aliases, visiting, complete);
			case Pointer(element) | Nullable(element) | Const(element) | Array(element, _):
				visitTypeAliases(element, aliases, visiting, complete);
			case _:
		}

	static function validateType(type:HxiType, names:Map<String, SourceSpan>, declarations:Map<String, HxiDeclaration>, span:SourceSpan, allowVoid:Bool):Void
		switch type {
			case Primitive("void") if (!allowVoid):
				fail("Void is not valid in this ABI position", span);
			case Primitive(_):
			case Named(name) if (!names.exists(name)):
				fail('Unknown HXI type "$name"', span);
			case Named(_):
			case Pointer(element):
				validateType(element, names, declarations, span, true);
			case Nullable(element):
				switch element {
					case Pointer(_):
					case Primitive("utf8"):
					case Named(name):
						switch declarations.get(name) {
							case Callback(_, _, _, _, _):
							case _: fail("nullable<> requires a pointer or callback type", span);
						}
					default: fail("nullable<> requires a pointer or callback type", span);
				}
				validateType(element, names, declarations, span, false);
			case Const(element):
				validateType(element, names, declarations, span, allowVoid);
			case Array(element, _):
				validateType(element, names, declarations, span, false);
		}

	static function declarationName(value:HxiDeclaration):{name:String, span:SourceSpan}
		return switch value {
			case Opaque(name, span) | Alias(name, _, span) | Handle(name, _, _, span) | Constant(name, _, span) | Structure(name, _, _, _, span) |
				Enumeration(name, _, _, _, span) | Callback(name, _, _, _, span) | Function(name, _, _, _, _, _, _, span):
				{name: name, span: span};
		}

	static function fail(message:String, span:SourceSpan):Dynamic
		throw new CompileError(new Diagnostic("E3001", message, span));
}
