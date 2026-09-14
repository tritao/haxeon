package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiHandleDisposition;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiType;

enum HxiSemanticParameterKind {
	InputValue(value:HxiAbiValue);
	InputArray(element:HxiAbiValue, count:String);
	InputBytes(count:String);
	OutputValue(value:HxiAbiValue);
	OutputHandle(handle:String, owned:Bool, release:Null<String>);
	OutputBuffer(size:String);
	OutputArray(element:HxiAbiValue, count:String);
	InOutValue(value:HxiAbiValue);
	RetainedCallback(callback:HxiAbiValue);
}

typedef HxiSemanticParameter = {
	final name:String;
	final kind:HxiSemanticParameterKind;
	final nativeValue:HxiAbiValue;
}

enum HxiSemanticResultKind {
	PlainValue(value:HxiAbiValue);
	BorrowedPointer(value:HxiAbiValue);
	OwnedPointer(value:HxiAbiValue, release:String);
	BorrowedHandle(name:String);
	OwnedHandle(name:String, destroy:String);
	ManagedBytes(length:String, value:HxiAbiValue, ownership:HxiOwnership, handleDisposition:HxiHandleDisposition);
}

typedef HxiSemanticFunction = {
	final name:String;
	final symbol:String;
	final parameters:Array<HxiSemanticParameter>;
	final result:HxiSemanticResultKind;
	final callConvention:String;
}

/** Validated, normalized meanings of the raw annotations and directions in one HXI interface. */
class HxiSemanticInterface {
	public final source:HxiInterface;
	public final functions:Array<HxiSemanticFunction>;
	public final byName:Map<String, HxiSemanticFunction>;

	public function new(source:HxiInterface, functions:Array<HxiSemanticFunction>) {
		this.source = source;
		this.functions = functions;
		byName = [];
		for (fn in functions)
			byName.set(fn.name, fn);
	}
}

/** Resolves raw HXI parameter and result annotations once after validation. */
class HxiSemantics {
	public static function normalize(model:HxiInterface, abi:HxiAbi, ?visibleDeclarations:Map<String, HxiDeclaration>):HxiSemanticInterface {
		var declarations:Map<String, HxiDeclaration> = [];
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations)
			declarations.set(declarationName(declaration), declaration);

		var functions:Array<HxiSemanticFunction> = [];
		for (declaration in model.declarations)
			switch declaration {
				case Function(name, parameters, result, symbol, _, callConvention, resultPolicy, _):
					var normalizedParameters = [for (parameter in parameters) normalizeParameter(parameter, abi, declarations)],
						nativeResult = abi.classify(result, true),
						semanticResult = normalizeResult(result, nativeResult, resultPolicy.ownership, resultPolicy.handleDisposition, resultPolicy.length,
							declarations);
					functions.push({
						name: name,
						symbol: symbol == null ? name : symbol,
						parameters: normalizedParameters,
						result: semanticResult,
						callConvention: callConvention
					});
				case _:
			}
		return new HxiSemanticInterface(model, functions);
	}

	static function normalizeParameter(parameter:HxiParameter, abi:HxiAbi, declarations:Map<String, HxiDeclaration>):HxiSemanticParameter {
		var nativeValue = abi.classify(parameter.type),
			kind:HxiSemanticParameterKind = switch parameter.direction {
				case In:
					if (parameter.retained) RetainedCallback(nativeValue); else InputValue(nativeValue);
				case InArray(count):
					if (isByteType(pointeeType(parameter.type), declarations, [])) InputBytes(count); else InputArray(pointeeValue(parameter.type, abi), count);
				case OutArray(count):
					OutputArray(pointeeValue(parameter.type, abi), count);
				case OutBuffer(size):
					OutputBuffer(size);
				case Out:
					normalizeOutput(parameter, abi, declarations, false);
				case InOut:
					normalizeOutput(parameter, abi, declarations, true);
			};
		return {name: parameter.name, kind: kind, nativeValue: nativeValue};
	}

	static function normalizeOutput(parameter:HxiParameter, abi:HxiAbi, declarations:Map<String, HxiDeclaration>, inout:Bool):HxiSemanticParameterKind {
		var valueType = pointeeType(parameter.type),
			value = abi.classify(valueType);
		return switch value {
			case HandleValue(name):
				var owned = parameter.handleDisposition == Owned;
				OutputHandle(name, owned, owned ? handleDestroy(name, declarations) : null);
			case PointerValue(_, _, opaquePointee, _) if (opaquePointee != null):
				var release = switch parameter.ownership {
					case Owned(symbol): symbol;
					case Borrowed | Unspecified: null;
				};
				OutputHandle(opaquePointee, release != null, release);
			case _:
				inout ? InOutValue(value) : OutputValue(value);
		};
	}

	static function normalizeResult(type:HxiType, value:HxiAbiValue, ownership:HxiOwnership, disposition:HxiHandleDisposition, length:Null<String>,
			declarations:Map<String, HxiDeclaration>):HxiSemanticResultKind {
		if (length != null)
			return ManagedBytes(length, value, ownership, disposition);
		if (disposition == Owned)
			return switch value {
				case HandleValue(name): OwnedHandle(name, handleDestroy(name, declarations));
				case _: throw "Validated owned HXI value handle did not classify as a handle";
			};
		return switch ownership {
			case Owned(release): OwnedPointer(value, release);
			case Borrowed:
				switch value {
					case HandleValue(name): BorrowedHandle(name);
					case PointerValue(_, _, _, _) | Utf8Value(_): BorrowedPointer(value);
					case _: PlainValue(value);
				}
			case Unspecified:
				switch value {
					case PointerValue(_, _, _, _) | Utf8Value(_): PlainValue(value);
					case _: PlainValue(value);
				}
		};
	}

	static function handleDestroy(name:String, declarations:Map<String, HxiDeclaration>):String
		return switch declarations.get(name) {
			case Handle(_, _, destroySymbol, _) if (destroySymbol != null): destroySymbol;
			case _: throw 'Validated owned HXI handle "$name" has no destructor';
		};

	static function pointeeValue(type:HxiType, abi:HxiAbi):HxiAbiValue
		return abi.classify(pointeeType(type));

	static function pointeeType(type:HxiType):HxiType
		return switch type {
			case Pointer(element) | Nullable(Pointer(element)): element;
			case Const(element): pointeeType(element);
			case _: throw "Expected pointer HXI type";
		};

	static function isByteType(type:HxiType, declarations:Map<String, HxiDeclaration>, visiting:Map<String, Bool>):Bool
		return switch type {
			case Primitive("void" | "i8" | "u8" | "c_char" | "c_schar" | "c_uchar"): true;
			case Const(element): isByteType(element, declarations, visiting);
			case Named(name) if (!visiting.exists(name)):
				switch declarations.get(name) {
					case Alias(_, target, _):
						visiting.set(name, true);
						var result = isByteType(target, declarations, visiting);
						visiting.remove(name);
						result;
					case _: false;
				}
			case _: false;
		};

	static function declarationName(value:HxiDeclaration):String
		return switch value {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};
}
