package compiler.ir;

import compiler.ir.Ir.IrType;

/**
 * A map keyed by an IR type's structure. Equal types are different enum values, so a key is hashed by walking the type and
 * compared with `IrTypeIdentity.same`: a lookup builds no text and allocates nothing, and only an insertion can grow the
 * table. Open addressing over parallel arrays, linear probing, never more than half full.
 */
class IrTypeMap<V> {
	var keys:Array<Null<IrType>>;
	var values:Array<Null<V>>;
	var hashes:Array<Int>;
	var count = 0;

	public function new() {
		keys = [];
		values = [];
		hashes = [];
		allocate(16);
	}

	public var size(get, never):Int;

	function get_size():Int
		return count;

	public function get(type:IrType):Null<V> {
		var slot = find(type, hash(type));
		return slot >= 0 ? values[slot] : null;
	}

	public function exists(type:IrType):Bool
		return find(type, hash(type)) >= 0;

	public function set(type:IrType, value:V):Void {
		var code = hash(type), slot = find(type, code);
		if (slot >= 0) {
			values[slot] = value;
			return;
		}
		if ((count + 1) * 2 > keys.length)
			grow();
		insert(type, code, value);
	}

	/** A table with the same entries, sharing nothing mutable with this one. */
	public function copy():IrTypeMap<V> {
		var result = new IrTypeMap<V>();
		result.keys = keys.copy();
		result.values = values.copy();
		result.hashes = hashes.copy();
		result.count = count;
		return result;
	}

	public function clear():Void {
		allocate(16);
		count = 0;
	}

	function find(type:IrType, code:Int):Int {
		var mask = keys.length - 1, slot = code & mask;
		while (true) {
			var key = keys[slot];
			if (key == null)
				return -1;
			if (hashes[slot] == code && IrTypeIdentity.same(key, type))
				return slot;
			slot = (slot + 1) & mask;
		}
	}

	function insert(type:IrType, code:Int, value:V):Void {
		var mask = keys.length - 1, slot = code & mask;
		while (keys[slot] != null)
			slot = (slot + 1) & mask;
		keys[slot] = type;
		values[slot] = value;
		hashes[slot] = code;
		count++;
	}

	function grow():Void {
		var oldKeys = keys, oldValues = values, oldHashes = hashes;
		allocate(keys.length * 2);
		count = 0;
		for (slot in 0...oldKeys.length) {
			var key = oldKeys[slot];
			if (key != null)
				insert(key, oldHashes[slot], cast oldValues[slot]);
		}
	}

	function allocate(capacity:Int):Void {
		keys = [];
		values = [];
		hashes = [];
		keys.resize(capacity);
		values.resize(capacity);
		hashes.resize(capacity);
		for (slot in 0...capacity) {
			keys[slot] = null;
			values[slot] = null;
			hashes[slot] = 0;
		}
	}

	/** A hash of the type's structure, consistent with `IrTypeIdentity.same`. */
	public static function hash(type:IrType):Int
		return mix(switch type {
			case Void: 1;
			case I32: 2;
			case I64: 3;
			case Bool: 4;
			case F32: 5;
			case F64: 6;
			case Bytes: 7;
			case RawPtr: 8;
			case ManagedBytes: 9;
			case Dyn: 10;
			case TypeRef: 11;
			case Nullable(element): mix(12) ^ hash(element);
			case Array(element): mix(13) ^ hash(element);
			case Iterator(element): mix(14) ^ hash(element);
			case Enum(name): mix(15) ^ text(name);
			case EnumTag(name): mix(16) ^ text(name);
			case Obj(name): mix(17) ^ text(name);
			case Abstract(name): mix(18) ^ text(name);
			case Virtual(name): mix(19) ^ text(name);
			case Function(arguments, result):
				var code = mix(20) ^ hash(result);
				for (argument in arguments)
					code = mix(code) ^ hash(argument);
				code;
		});

	static function text(value:String):Int {
		var code = -2128831035;
		for (index in 0...value.length)
			code = (code ^ StringTools.fastCodeAt(value, index)) * 16777619;
		return code;
	}

	static inline function mix(value:Int):Int {
		var code = value * -1640531535;
		return code ^ (code >>> 15);
	}
}
