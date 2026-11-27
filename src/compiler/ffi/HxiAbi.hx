package compiler.ffi;

import compiler.core.InternalError;
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

/** A C record laid out field by field: each at the next offset its alignment allows, the size padded to the alignment. */
typedef HxiRecordLayout = {size:Int, align:Int, offsets:Array<Int>}

/** Resolves target-dependent C types without conflating them with fixed-width types. */
class HxiAbi {
	public final target:String;
	public final interfaceName:Null<String>;
	public final pointerBits:Int;
	public final longBits:Int;
	public final wcharBits:Int;

	/** Largest alignment of a scalar field: 64-bit scalars align to 4 only on the System V i386 ABI. */
	public final scalarAlignLimit:Int;

	final declarations:Map<String, HxiDeclaration> = [];
	final records:Map<String, HxiTypeLayout>;
	final structLayouts:Map<String, HxiRecordLayout> = [];
	final model:Null<HxiInterface>;
	final classifications:Map<String, HxiAbiValue> = [];
	final flagMasks:Map<String, haxe.Int64> = [];
	final voidClassifications:Map<String, HxiAbiValue> = [];
	var cachedFunctions:Null<Array<HxiFunctionAbi>>;

	public static function forInterface(model:HxiInterface, ?visibleDeclarations:Map<String, HxiDeclaration>):HxiAbi
		return new HxiAbi(model, model.target, visibleDeclarations, null);

	/** Create an ABI classifier for source-declared native records, `records` the layouts of the records they nest. */
	public static function forTarget(target:String, ?visibleDeclarations:Map<String, HxiDeclaration>,
			?records:Map<String, HxiTypeLayout>):HxiAbi
		return new HxiAbi(null, target, visibleDeclarations, records);

	function new(model:Null<HxiInterface>, target:String, visibleDeclarations:Null<Map<String, HxiDeclaration>>,
			records:Null<Map<String, HxiTypeLayout>>) {
		if (target == HxiInterface.PORTABLE)
			throw new InternalError('A portable HXI interface needs a profile before it has an ABI');
		this.model = model;
		this.records = records == null ? [] : records;
		this.interfaceName = model == null ? null : model.name;
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
			default: throw new InternalError('Unsupported HXI target architecture "$architecture"');
		}
		var windows = this.target.indexOf("windows") >= 0 || this.target.indexOf("mingw") >= 0
			|| this.target.indexOf("msvc") >= 0;
		longBits = windows ? 32 : pointerBits;
		wcharBits = windows ? 16 : 32;
		scalarAlignLimit = switch architecture {
			case "i386" | "i486" | "i586" | "i686" | "x86": windows ? 8 : 4;
			// Wasm32 and ARM (AAPCS) align 64-bit scalars to 8, as does the portable 32-bit profile audited on Wasm.
			default: 8;
		};
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
			throw new InternalError("A target-only HXI ABI has no function declarations");
		cachedFunctions = HxiNativeSignature.lower(model, this, declarations);
		return cachedFunctions;
	}

	/** Resolve the shared HXI/native-record size and alignment model. */
	public function layout(type:HxiType):Null<HxiTypeLayout>
		return typeLayout(type, []);

	/** The layout of struct `name` on this ABI, or null when it is not a struct or a field has no fixed C layout. */
	public function findStructLayout(name:String):Null<HxiRecordLayout>
		return structureLayout(name, []);

	/** The layout of struct `name`, which validation has given a fixed C layout. */
	public function structLayout(name:String):HxiRecordLayout {
		var layout = structureLayout(name, []);
		if (layout == null)
			throw new InternalError('Struct "$name" has no fixed C layout');
		return layout;
	}

	/** The offset of field `field` in struct `owner` on this ABI. */
	public function fieldOffset(owner:String, field:String):Int {
		var layout = structLayout(owner);
		switch declarations.get(owner) {
			case Structure(_, fields, _):
				for (index in 0...fields.length)
					if (fields[index].name == field)
						return layout.offsets[index];
			case _:
		}
		throw new InternalError('Struct "$owner" has no laid-out field "$field"');
	}

	/** Lay out fields of the given types in order, each of which has a fixed C layout. */
	public function recordLayout(types:Array<HxiType>):HxiRecordLayout {
		var layout = placeFields(types, []);
		if (layout == null)
			throw new InternalError("A native record field has no fixed C layout");
		return layout;
	}

	function structureLayout(name:String, resolving:Map<String, Bool>):Null<HxiRecordLayout> {
		var cached = structLayouts.get(name);
		if (cached != null)
			return cached;
		var fields = switch declarations.get(name) {
			case Structure(_, fields, _): fields;
			case _: return null;
		};
		if (fields.length == 0 || resolving.exists(name))
			return null;
		resolving.set(name, true);
		var layout = placeFields([for (field in fields) field.type], resolving);
		resolving.remove(name);
		if (layout != null)
			structLayouts.set(name, layout);
		return layout;
	}

	function placeFields(types:Array<HxiType>, resolving:Map<String, Bool>):Null<HxiRecordLayout> {
		var offsets:Array<Int> = [], cursor = 0, align = 1;
		for (type in types) {
			var field = typeLayout(type, resolving);
			if (field == null || field.size <= 0 || field.align <= 0)
				return null;
			cursor = alignUp(cursor, field.align);
			if (cursor > 0x7FFFFFFF - field.size)
				throw new InternalError("Native record layout exceeds the supported size");
			offsets.push(cursor);
			cursor += field.size;
			if (field.align > align)
				align = field.align;
		}
		return {size: alignUp(cursor, align), align: align, offsets: offsets};
	}

	static function alignUp(value:Int, alignment:Int):Int {
		var remainder = value % alignment;
		if (remainder == 0)
			return value;
		var padding = alignment - remainder;
		if (value > 0x7FFFFFFF - padding)
			throw new InternalError("Native record layout exceeds the supported size");
		return value + padding;
	}

	function typeLayout(type:HxiType, resolving:Map<String, Bool>):Null<HxiTypeLayout>
		return switch type {
			case Const(element): typeLayout(element, resolving);
			case Nullable(element): pointerLike(element) ? typeLayout(element, resolving) : null;
			case Pointer(_): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
			case Primitive("utf8"): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
			case Array(element, length): var item = typeLayout(element,
				resolving);
				item == null || length < 0 || (length != 0
					&& item.size > Std.int(0x7FFFFFFF / length)) ? null : {
						size: item.size * length,
						align: item.align
					};
			case Primitive(_):
				switch classify(type) {
					case IntegerValue(bits, _), EnumerationValue(_, bits, _), FloatValue(bits):
						var size = Std.int(bits / 8);
						{
							size:size, align:size < scalarAlignLimit ? size : scalarAlignLimit
						};
					case Boolean32Value: {size: 4, align: 4};
					case HandleValue(_): {size: 4, align: 4};
					case PointerValue(_, _, _, _) | Utf8Value(_): {
						size: Std.int(pointerBits / 8),
						align: Std.int(pointerBits / 8)
					};
					case CallbackValue(_, _, _, _): {size: Std.int(pointerBits / 8), align: Std.int(pointerBits / 8)};
					case AggregateValue(_, size, align): {size: size, align: align};
					case _: null;
				}
			case Named(name):
				var declaration = declarations.get(name);
				if (records.exists(name)) records.get(name);
				else if (declaration != null && declaration.match(Structure(_, _, _))) {
					// structureLayout tracks the structs being laid out, which a by-value cycle comes back to.
					var record = structureLayout(name, resolving);
					record == null ? null : {size: record.size, align: record.align};
				} else if (resolving.exists(name)) null;
				else {
					resolving.set(name, true);
					var result = switch declaration {
						case Alias(_, target, _): typeLayout(target, resolving);
						case Handle(_, _, _, _): {size: 4, align: 4};
						case Enumeration(_, representation, _, _, _): typeLayout(representation, resolving);
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

	/** Native enums retain their nominal type while sharing the integer call ABI. */
	public function isEnumValue(value:HxiAbiValue):Bool
		return switch value {
			case EnumerationValue(_, _, _): true;
			default: false;
		};

	public function isFlagsValue(value:HxiAbiValue):Bool
		return switch value {
			case EnumerationValue(name, _, _): switch declarations.get(name) {
					case Enumeration(_, _, true, _, _): true;
					default: false;
				};
			default: false;
		};

	/** The schema is immutable; compute each native flags mask once per ABI. */
	public function flagsMask(name:String):haxe.Int64 {
		if (flagMasks.exists(name))
			return flagMasks.get(name);
		var mask = haxe.Int64.ofInt(0);
		switch declarations.get(name) {
			case Enumeration(_, _, true, values, _):
				for (value in values)
					mask = haxe.Int64.or(mask, value.value);
			default:
				throw new InternalError('Not a native flags declaration "$name"');
		}
		flagMasks.set(name, mask);
		return mask;
	}

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
					throw new InternalError("Void has no value ABI");
				VoidValue;
			case Primitive("bool32"): Boolean32Value;
			case Primitive(name): classifyPrimitive(name);
			case Pointer(element): PointerValue(pointerBits, false, opaquePointee(element), structurePointee(element));
			case Nullable(element):
				switch classify(element, allowVoid) {
					case PointerValue(bits, _, opaquePointee, structure): PointerValue(bits, true, opaquePointee,
						structure);
					case CallbackValue(name, arguments, result, _): CallbackValue(name, arguments, result, true);
					case Utf8Value(_): Utf8Value(true);
					case _: throw new InternalError("Nullable ABI value must be a pointer");
				}
			case Const(element): classify(element, allowVoid);
			case Array(_, _): throw new InternalError("C arrays cannot be passed by value");
			case Named(name):
				var declaration = declarations.get(name);
				if (declaration == null)
					throw new InternalError('Unknown HXI type "$name"');
				switch declaration {
					case Alias(_, target, _): classify(target, allowVoid);
					case Handle(handleName, representation, _, _):
						switch classify(representation, allowVoid) {
							case IntegerValue(32, Unsigned): HandleValue(handleName);
							case _: throw new InternalError('Handle HXI type "$name" requires an unsigned 32-bit representation');
						}
					case Enumeration(_, representation, _, _, _):
						switch classify(representation, allowVoid) {
							case IntegerValue(bits, sign): EnumerationValue(name, bits, sign);
							case _: throw new InternalError('Enum HXI type "$name" does not have an integer representation');
						}
					case Callback(_, parameters, result, _, _):
						CallbackValue(name, [for (parameter in parameters) classify(parameter.type)],
							classify(result, true), false);
					case Structure(_, _, _):
						var record = structLayout(name);
						AggregateValue(name, record.size, record.align);
					case Opaque(_, _): throw new InternalError('Opaque HXI type "$name" cannot be passed by value');
					case _: throw new InternalError('HXI declaration "$name" is not a type');
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
					case Structure(_, _, _): name;
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
			default: throw new InternalError('Unsupported primitive HXI type "$name"');
		};

	public static function nameOf(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _,
				_) | Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _,
				_): name;
		};
}
