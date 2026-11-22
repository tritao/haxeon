package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.ir.model.IrTypeMap;

/**
 * Dense numbers for the questions lowering puts to the symbol tables and the function layout (`HlSymbolRequest`): one number per
 * question, whatever function or build asked it, so a lowered function keeps its requests as two arrays of numbers, the distinct
 * questions in the order it first asked them and the answer each got (`HlLoweredFunction.keys` and `answers`). Linking asks each
 * question at most once per build (`HlRequestAnswers`), so a function whose answers all stand costs an array read per request.
 *
 * The session keeps one, with the lowered functions (`HlLoweredCache`); it only grows, so the copies of the cache share it.
 */
class HlRequestKeys {
	/** Questions by number, as first asked: the index in them is the asker's, which a replay ignores. */
	final requests:Array<HlSymbolRequest> = [];

	/** By number, which table the answer indexes (`HlRemap`), or `CHECK` for a position that must not move. */
	final tables:Array<Int> = [];

	/** By number, whether asking adds to the tables, so asking it in another order would order them differently. */
	final interning:Array<Bool> = [];

	final ints:Map<Int, Int> = [];
	final floats:Map<String, Int> = [];
	final strings:Map<String, Int> = [];
	final literals:Map<String, Int> = [];
	final functions:Map<String, Int> = [];
	final globals:Map<String, Int> = [];
	final types = new IrTypeMap<Int>();
	final references = new IrTypeMap<Int>();

	/** The rest, which lowering asks far less often, by a text key. */
	final others:Map<String, Int> = [];

	/** By number, the symbol table's key of the type a type request names (`HlSymbolTable.typeKey`), made when first asked. */
	final typeKeys:Array<Null<String>> = [];

	/** `seen[key]` is `recording` when the function being recorded asked `key` already. */
	final seen:Array<Int> = [];

	var recording = 0;

	public static inline final INTS = 0;
	public static inline final FLOATS = 1;
	public static inline final STRINGS = 2;
	public static inline final TYPES = 3;
	public static inline final GLOBALS = 4;
	public static inline final FUNCTIONS = 5;
	public static inline final CHECK = -1;

	public function new() {}

	public var count(get, never):Int;

	inline function get_count():Int
		return requests.length;

	public inline function request(key:Int):HlSymbolRequest
		return requests[key];

	public inline function table(key:Int):Int
		return tables[key];

	public inline function interns(key:Int):Bool
		return interning[key];

	/** The symbol table's key of the type request `key` names (a `TypeOf` or `RefTo`). */
	public function typeKey(key:Int, type:compiler.ir.model.Ir.IrType):String {
		var known = typeKeys[key];
		if (known == null) {
			known = HlSymbolTable.typeKey(type);
			typeKeys[key] = known;
		}
		return known;
	}

	/** Starts recording a function's requests (`record`). */
	public function startFunction():Void
		recording++;

	/**
	 * Notes `request` for the function being recorded: appends its number and answer to `keys` and `answers` unless the function
	 * asked it already (asking again changes nothing, and the answer is the same).
	 */
	public function record(request:HlSymbolRequest, keys:Array<Int>, answers:Array<Int>):Void {
		var key = keyOf(request);
		if (seen[key] == recording)
			return;
		seen[key] = recording;
		keys.push(key);
		answers.push(answerOf(request));
	}

	/** The answer `request` recorded, as `HlRequestAnswers.answer` gives it. */
	static function answerOf(request:HlSymbolRequest):Int
		return switch request {
			case ConstInt(_, index) | ConstFloat(_, index) | ConstString(_, index) | TypeOf(_, index) | RefTo(_, index)
				| RuntimeHeader(_, index) | GlobalSlot(_, _, index) | GlobalByName(_, index) | StringLiteral(_, index)
				| EnumValue(_, _, index) | FunctionRef(_, index) | MethodSlot(_, _, index) | InterfaceSlot(_, _, index):
				index;
			case NativeStorage(_, _, index) | FieldSlot(_, _, index): index == null ? HlRequestAnswers.NONE : index;
			case MethodSlotKnown(_, _, answer): answer;
		};

	function keyOf(request:HlSymbolRequest):Int {
		var known:Null<Int> = switch request {
			case ConstInt(value, _): ints.get(value);
			case ConstFloat(value, _): floats.get(floatKey(value));
			case ConstString(value, _): strings.get(value);
			case TypeOf(type, _): types.get(type);
			case RefTo(type, _): references.get(type);
			case StringLiteral(value, _): literals.get(value);
			case GlobalByName(name, _): globals.get(name);
			case FunctionRef(name, _): functions.get(name);
			default: others.get(otherKey(request));
		};
		if (known != null)
			return known;
		var key = requests.length;
		requests.push(request);
		seen.push(0);
		typeKeys.push(null);
		switch request {
			case ConstInt(value, _): ints.set(value, key);
			case ConstFloat(value, _): floats.set(floatKey(value), key);
			case ConstString(value, _): strings.set(value, key);
			case TypeOf(type, _): types.set(type, key);
			case RefTo(type, _): references.set(type, key);
			case StringLiteral(value, _): literals.set(value, key);
			case GlobalByName(name, _): globals.set(name, key);
			case FunctionRef(name, _): functions.set(name, key);
			default: others.set(otherKey(request), key);
		}
		tables.push(switch request {
			case ConstInt(_, _): INTS;
			case ConstFloat(_, _): FLOATS;
			case ConstString(_, _): STRINGS;
			case TypeOf(_, _) | RefTo(_, _) | RuntimeHeader(_, _) | NativeStorage(_, _, _): TYPES;
			case GlobalSlot(_, _, _) | GlobalByName(_, _) | StringLiteral(_, _) | EnumValue(_, _, _): GLOBALS;
			case FunctionRef(_, _): FUNCTIONS;
			case FieldSlot(_, _, _) | MethodSlot(_, _, _) | InterfaceSlot(_, _, _) | MethodSlotKnown(_, _, _): CHECK;
		});
		interning.push(switch request {
			case GlobalByName(_, _) | FunctionRef(_, _) | FieldSlot(_, _, _) | MethodSlot(_, _, _) | InterfaceSlot(_, _,
				_) | MethodSlotKnown(_, _, _): false;
			default: true;
		});
		return key;
	}

	/** Floats are told apart by their bits, as the symbol table pools them. */
	static function floatKey(value:Float):String {
		var bits = haxe.io.Bytes.alloc(8);
		bits.setDouble(0, value);
		return bits.getInt32(0) + ":" + bits.getInt32(4);
	}

	static function otherKey(request:HlSymbolRequest):String
		return switch request {
			case RuntimeHeader(kind, _): "header\n" + Std.string(kind);
			case NativeStorage(type, layout,
				_): "storage\n" + compiler.ir.model.IrTypeIdentity.text(type) + "\n" + layout.size + "\n"
				+ layout.signed;
			case GlobalSlot(name, type, _): "global\n" + name + "\n" + compiler.ir.model.IrTypeIdentity.text(type);
			case EnumValue(enumName, constructor, _): "enum\n" + enumName + "\n" + constructor;
			case FieldSlot(owner, name, _): "field\n" + owner + "\n" + name;
			case MethodSlot(typeName, name, _): "method\n" + typeName + "\n" + name;
			case InterfaceSlot(interfaceName, name, _): "interface\n" + interfaceName + "\n" + name;
			case MethodSlotKnown(typeName, name, _): "known\n" + typeName + "\n" + name;
			default: throw new InternalError('request ${Std.string(request)} has a key of its own');
		};
}
