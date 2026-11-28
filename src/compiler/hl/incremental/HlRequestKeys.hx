package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.ir.model.IrTypeIds;

/**
 * Dense numbers for the questions lowering puts to the symbol tables and the function layout (`HlSymbolRequest`): one number per
 * question, whatever function or build asked it, so a lowered function keeps its requests as two arrays of numbers, the distinct
 * questions in the order it first asked them and the answer each got (`HlLoweredFunction.keys` and `answers`). Linking asks each
 * question at most once per build (`HlRequestAnswers`), so a function whose answers all stand costs an array read per request.
 *
 * The session keeps one, with the lowered functions (`HlFunctionQueries`); it only grows, so the copies of the session share it.
 */
class HlRequestKeys {
	/** Questions by number, as first asked: the index in them is the asker's answer, which another build may answer otherwise. */
	final requests:Array<HlSymbolRequest> = [];

	/** By number, which table the answer indexes (`HlRemap`), or `CHECK` for a position that must not move. */
	final tables:Array<Int> = [];

	final ints:Map<Int, Int> = [];
	final floats:Map<String, Int> = [];
	final strings:Map<String, Int> = [];
	final literals:Map<String, Int> = [];
	final functions:Map<String, Int> = [];
	final globals:Map<String, Int> = [];

	/**
	 * By type id, the number of the type's request (`TypeOf`) and of its reference's (`RefTo`), or -1: lowering asks one for every
	 * register, so finding it is an array read.
	 */
	final types:Array<Int> = [];

	final references:Array<Int> = [];

	/** The rest, which lowering asks far less often, by a text key. */
	final others:Map<String, Int> = [];

	/** By type id, the symbol table's key of the type (`HlSymbolTable.typeKey`), made when a type request first needs it. */
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

	/** The symbol table's key of the type with id `type`, which a `TypeOf` or `RefTo` names. */
	public function typeKey(type:Int):String {
		var known = type < typeKeys.length ? typeKeys[type] : null;
		if (known == null) {
			known = HlSymbolTable.typeKey(IrTypeIds.type(type));
			typeKeys[type] = known;
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
	public function record(request:HlSymbolRequest, keys:Array<Int>, answers:Array<Int>):Void
		recordKey(keyOf(request), answerOf(request), keys, answers);

	/** `record` of `TypeOf(type, index)`, which lowering asks for every register: it makes the request only when it is new. */
	public function recordType(type:Int, index:Int, keys:Array<Int>, answers:Array<Int>):Void {
		var key = byType(types, type);
		recordKey(key >= 0 ? key : keyOf(TypeOf(type, index)), index, keys, answers);
	}

	function recordKey(key:Int, answer:Int, keys:Array<Int>, answers:Array<Int>):Void {
		if (seen[key] == recording)
			return;
		seen[key] = recording;
		keys.push(key);
		answers.push(answer);
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

	/** The number of `request`, given the first time it is asked. */
	public function keyOf(request:HlSymbolRequest):Int {
		var known:Null<Int> = switch request {
			case ConstInt(value, _): ints.get(value);
			case ConstFloat(value, _): floats.get(floatKey(value));
			case ConstString(value, _): strings.get(value);
			case TypeOf(type, _): byType(types, type);
			case RefTo(type, _): byType(references, type);
			case StringLiteral(value, _): literals.get(value);
			case GlobalByName(name, _): globals.get(name);
			case FunctionRef(name, _): functions.get(name);
			default: others.get(otherKey(request));
		};
		if (known != null && known >= 0)
			return known;
		var key = requests.length;
		requests.push(request);
		seen.push(0);
		switch request {
			case ConstInt(value, _): ints.set(value, key);
			case ConstFloat(value, _): floats.set(floatKey(value), key);
			case ConstString(value, _): strings.set(value, key);
			case TypeOf(type, _): setByType(types, type, key);
			case RefTo(type, _): setByType(references, type, key);
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
		return key;
	}

	static inline function byType(keys:Array<Int>, type:Int):Int
		return type < keys.length ? keys[type] : -1;

	static function setByType(keys:Array<Int>, type:Int, key:Int):Void {
		while (keys.length <= type)
			keys.push(-1);
		keys[type] = key;
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
