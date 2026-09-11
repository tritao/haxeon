package compiler.ffi;

import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiResultPolicy;

enum HxiIntegerSign {
	Signed;
	Unsigned;
	PlainChar;
}

enum HxiAbiValue {
	VoidValue;
	IntegerValue(bits:Int, sign:HxiIntegerSign);
	EnumerationValue(name:String, bits:Int, sign:HxiIntegerSign);
	HandleValue(name:String);
	CallbackValue(name:String, arguments:Array<HxiAbiValue>, result:HxiAbiValue, nullable:Bool);
	FloatValue(bits:Int);
	PointerValue(bits:Int, nullable:Bool, opaque:Bool, structure:Null<String>);
	Utf8Value(nullable:Bool);
	AggregateValue(name:String, size:Int, align:Int);
}

typedef HxiFunctionAbi = {
	final name:String;
	final symbol:String;
	final library:Null<String>;
	final arguments:Array<HxiAbiValue>;
	final result:HxiAbiValue;
	final leaf:Bool;
	final callConvention:String;
	final resultPolicy:HxiResultPolicy;
}

/** Resolves target-dependent C types without conflating them with fixed-width types. */
class HxiAbi {
	public final target:String;
	public final pointerBits:Int;
	public final longBits:Int;
	public final wcharBits:Int;

	final declarations:Map<String, HxiDeclaration> = [];
	final model:HxiInterface;
	final classifications:Map<String, HxiAbiValue> = [];
	var cachedFunctions:Null<Array<HxiFunctionAbi>>;

	public static function forInterface(model:HxiInterface, ?visibleDeclarations:Map<String, HxiDeclaration>):HxiAbi
		return new HxiAbi(model, visibleDeclarations);

	function new(model:HxiInterface, visibleDeclarations:Null<Map<String, HxiDeclaration>>) {
		this.model = model;
		target = model.target.toLowerCase();
		var architecture = target == "portable-abi64" ? "portable64" : target.split("-")[0];
		pointerBits = switch architecture {
			case "i386" | "i486" | "i586" | "i686" | "x86" | "arm" | "armv7" | "wasm32": 32;
			case "x86_64" | "amd64" | "aarch64" | "arm64" | "riscv64" | "wasm64": 64;
			case "portable64": 64;
			default: throw 'Unsupported HXI target architecture "$architecture"';
		}
		var windows = target.indexOf("windows") >= 0 || target.indexOf("mingw") >= 0 || target.indexOf("msvc") >= 0;
		longBits = windows ? 32 : pointerBits;
		wcharBits = windows ? 16 : 32;
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations)
			declarations.set(nameOf(declaration), declaration);
	}

	public function functions():Array<HxiFunctionAbi> {
		if (cachedFunctions != null)
			return cachedFunctions;
		var result:Array<HxiFunctionAbi> = [];
		for (declaration in model.declarations)
			switch declaration {
				case Function(name, parameters, returnType, symbol, leaf, callConvention, resultPolicy, _):
					result.push({
						name: name,
						symbol: symbol == null ? name : symbol,
						library: model.library,
						arguments: [for (parameter in parameters) classify(parameter.type, false)],
						result: classify(returnType, true),
						leaf: leaf,
						callConvention: callConvention,
						resultPolicy: resultPolicy
					});
				default:
			}
		cachedFunctions = result;
		return result;
	}

	public function classify(type:HxiType, allowVoid:Bool = false):HxiAbiValue {
		var key = (allowVoid ? "allow-void:" : "value:") + typeKey(type),
			cached = classifications.get(key);
		if (cached != null)
			return cached;
		var result = switch type {
			case Primitive("void"):
				if (!allowVoid)
					throw "Void has no value ABI";
				VoidValue;
			case Primitive(name): classifyPrimitive(name);
			case Pointer(element): PointerValue(pointerBits, false, opaquePointee(element), structurePointee(element));
			case Nullable(element):
				switch classify(element, allowVoid) {
					case PointerValue(bits, _, opaque, structure): PointerValue(bits, true, opaque, structure);
					case CallbackValue(name, arguments, result, _): CallbackValue(name, arguments, result, true);
					case Utf8Value(_): Utf8Value(true);
					case _: throw "Nullable ABI value must be a pointer";
				}
			case Const(element): classify(element, allowVoid);
			case Array(_, _): throw "C arrays cannot be passed by value";
			case Named(name):
				var declaration = declarations.get(name);
				if (declaration == null)
					throw 'Unknown HXI type "$name"';
				switch declaration {
					case Alias(_, target, _): classify(target, allowVoid);
					case Handle(handleName, representation, _):
						switch classify(representation, allowVoid) {
							case IntegerValue(32, Unsigned): HandleValue(handleName);
							case _: throw 'Handle HXI type "$name" requires an unsigned 32-bit representation';
						}
					case Enumeration(_, representation, _, _, _):
						switch classify(representation, allowVoid) {
							case IntegerValue(bits, sign): EnumerationValue(name, bits, sign);
							case _: throw 'Enum HXI type "$name" does not have an integer representation';
						}
					case Callback(_, parameters, result, _, _):
						CallbackValue(name, [for (parameter in parameters) classify(parameter.type)], classify(result, true), false);
					case Structure(_, size, align, _, _): AggregateValue(name, size, align);
					case Opaque(_, _): throw 'Opaque HXI type "$name" cannot be passed by value';
					case _: throw 'HXI declaration "$name" is not a type';
				}
		};
		classifications.set(key, result);
		return result;
	}

	function typeKey(type:HxiType):String
		return switch type {
			case Primitive(name): "primitive:" + name;
			case Named(name): "named:" + name;
			case Pointer(element): "pointer<" + typeKey(element) + ">";
			case Nullable(element): "nullable<" + typeKey(element) + ">";
			case Const(element): "const<" + typeKey(element) + ">";
			case Array(element, length): "array<" + typeKey(element) + "," + length + ">";
		};

	function structurePointee(type:HxiType):Null<String>
		return switch type {
			case Const(element): structurePointee(element);
			case Named(name):
				switch declarations.get(name) {
					case Structure(_, _, _, _, _): name;
					case Alias(_, target, _): structurePointee(target);
					case _: null;
				}
			case _: null;
		};

	function opaquePointee(type:HxiType):Bool
		return switch type {
			case Const(element): opaquePointee(element);
			case Named(name):
				switch declarations.get(name) {
					case Opaque(_, _): true;
					case Alias(_, target, _): opaquePointee(target);
					case _: false;
				}
			case _: false;
		};

	function classifyPrimitive(name:String):HxiAbiValue
		return switch name {
			case "i8" | "c_schar": IntegerValue(8, Signed);
			case "c_char": IntegerValue(8, PlainChar);
			case "u8" | "c_uchar" | "c_bool": IntegerValue(8, Unsigned);
			case "i16" | "c_short": IntegerValue(16, Signed);
			case "u16" | "c_ushort": IntegerValue(16, Unsigned);
			case "i32" | "c_int": IntegerValue(32, Signed);
			case "u32" | "c_uint": IntegerValue(32, Unsigned);
			case "i64" | "c_long_long": IntegerValue(64, Signed);
			case "u64" | "c_ulong_long": IntegerValue(64, Unsigned);
			case "isize": IntegerValue(pointerBits, Signed);
			case "usize" | "c_size": IntegerValue(pointerBits, Unsigned);
			case "c_long": IntegerValue(longBits, Signed);
			case "c_ulong": IntegerValue(longBits, Unsigned);
			case "c_wchar": IntegerValue(wcharBits, wcharBits == 16 ? Unsigned : Signed);
			case "f32": FloatValue(32);
			case "f64": FloatValue(64);
			case "utf8": Utf8Value(false);
			default: throw 'Unsupported primitive HXI type "$name"';
		};

	static function nameOf(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};
}
