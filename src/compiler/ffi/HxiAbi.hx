package compiler.ffi;

import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;

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
	Boolean32Value;
	CallbackValue(name:String, arguments:Array<HxiAbiValue>, result:HxiAbiValue, nullable:Bool);
	FloatValue(bits:Int);
	PointerValue(bits:Int, nullable:Bool, opaquePointee:Null<String>, structure:Null<String>);
	Utf8Value(nullable:Bool);
	AggregateValue(name:String, size:Int, align:Int);
}

/** Concrete size and alignment of one fixed-layout ABI type, in bytes. */
typedef HxiTypeLayout = {size:Int, align:Int}

/** Resolves target-dependent C types without conflating them with fixed-width types. */
class HxiAbi {
	public final target:String;
	public final pointerBits:Int;
	public final longBits:Int;
	public final wcharBits:Int;

	final declarations:Map<String, HxiDeclaration> = [];
	final model:Null<HxiInterface>;
	final classifications:Map<String, HxiAbiValue> = [];
	final voidClassifications:Map<String, HxiAbiValue> = [];
	var cachedFunctions:Null<Array<HxiFunctionAbi>>;

	public static function forInterface(model:HxiInterface, ?visibleDeclarations:Map<String, HxiDeclaration>):HxiAbi
		return new HxiAbi(model, model.target, visibleDeclarations);

	/** Create an ABI classifier for source-declared native records. */
	public static function forTarget(target:String, ?visibleDeclarations:Map<String, HxiDeclaration>):HxiAbi
		return new HxiAbi(null, target, visibleDeclarations);

	function new(model:Null<HxiInterface>, target:String, visibleDeclarations:Null<Map<String, HxiDeclaration>>) {
		this.model = model;
		this.target = target.toLowerCase();
		var architecture = switch this.target {
			case "portable-abi64": "portable64";
			case "portable-abi32": "portable32";
			default: target.split("-")[0];
		};
		pointerBits = switch architecture {
			case "i386" | "i486" | "i586" | "i686" | "x86" | "arm" | "armv7" | "wasm32": 32;
			case "x86_64" | "amd64" | "aarch64" | "arm64" | "riscv64" | "wasm64": 64;
			case "portable32": 32;
			case "portable64": 64;
			default: throw 'Unsupported HXI target architecture "$architecture"';
		}
		var windows = this.target.indexOf("windows") >= 0 || this.target.indexOf("mingw") >= 0 || this.target.indexOf("msvc") >= 0;
		longBits = windows ? 32 : pointerBits;
		wcharBits = windows ? 16 : 32;
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		if (model != null)
			for (declaration in model.declarations)
				declarations.set(nameOf(declaration), declaration);
	}

	public function functions():Array<HxiFunctionAbi> {
		if (cachedFunctions != null)
			return cachedFunctions;
		if (model == null)
			throw "A target-only HXI ABI has no function declarations";
		cachedFunctions = HxiNativeSignature.lower(model, this, declarations);
		return cachedFunctions;
	}

	/** Resolve the shared HXI/native-record size and alignment model. */
	public function layout(type:HxiType):Null<HxiTypeLayout>
		return typeLayout(type, []);

	function typeLayout(type:HxiType, resolving:Map<String, Bool>):Null<HxiTypeLayout>
		return switch type {
			case Const(element): typeLayout(element, resolving);
			case Nullable(element): pointerLike(element) ? typeLayout(element, resolving) : null;
			case Pointer(_): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
			case Primitive("utf8"): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
			case Array(element, length): var item = typeLayout(element,
					resolving); item == null || length < 0 || (length != 0
					&& item.size > Std.int(0x7FFFFFFF / length)) ? null : {size: item.size * length, align: item.align};
			case Primitive(_):
				switch classify(type) {
					case IntegerValue(bits, _), EnumerationValue(_, bits, _), FloatValue(bits):
						var size = Std.int(bits / 8);
						{size: size, align: Std.int(Math.min(size, pointerBits / 8))};
					case Boolean32Value: {size: 4, align: 4};
					case HandleValue(_): {size: 4, align: 4};
					case PointerValue(_, _, _, _) | Utf8Value(_): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
					case CallbackValue(_, _, _, _): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
					case AggregateValue(_, size, align): {size: size, align: align};
					case _: null;
				}
			case Named(name):
				if (resolving.exists(name)) null; else {
					resolving.set(name, true);
					var result = switch declarations.get(name) {
						case Alias(_, target, _): typeLayout(target, resolving);
						case Handle(_, _, _, _): {size: 4, align: 4};
						case Enumeration(_, representation, _, _, _): typeLayout(representation, resolving);
						case Structure(_, size, align, _, _): {size: size, align: align};
						case Callback(_, _, _, _, _): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
						case _: null;
					};
					resolving.remove(name);
					result;
				}
		};

	function pointerLike(type:HxiType):Bool
		return switch type {
			case Pointer(_), Primitive("utf8"): true;
			case Nullable(element) | Const(element): pointerLike(element);
			case _: false;
		};

	public function semanticDeclarations():Map<String, HxiDeclaration>
		return declarations.copy();

	public function classify(type:HxiType, allowVoid:Bool = false):HxiAbiValue {
		var key = typeKey(type),
			cache = allowVoid ? voidClassifications : classifications,
			cached = cache.get(key);
		if (cached != null)
			return cached;
		var result = switch type {
			case Primitive("void"):
				if (!allowVoid)
					throw "Void has no value ABI";
				VoidValue;
			case Primitive("bool32"): Boolean32Value;
			case Primitive(name): classifyPrimitive(name);
			case Pointer(element): PointerValue(pointerBits, false, opaquePointee(element), structurePointee(element));
			case Nullable(element):
				switch classify(element, allowVoid) {
					case PointerValue(bits, _, opaquePointee, structure): PointerValue(bits, true, opaquePointee, structure);
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
					case Handle(handleName, representation, _, _):
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
		cache.set(key, result);
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

	function opaquePointee(type:HxiType):Null<String>
		return switch type {
			case Const(element): opaquePointee(element);
			case Named(name):
				switch declarations.get(name) {
					case Opaque(_, _): name;
					case Alias(_, target, _): opaquePointee(target);
					case _: null;
				}
			case _: null;
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
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};
}
