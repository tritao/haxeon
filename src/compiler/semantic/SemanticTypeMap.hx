package compiler.semantic;

import compiler.core.InternalError;
import compiler.types.FunctionTypes;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/**
 * A map keyed by a semantic type as `SemanticSignature.type` identifies it, without spelling it: a key is hashed by walking the
 * type and compared with `same`, so a lookup builds no text and allocates nothing; only an insertion can grow the table. For
 * tables whose text keys would be spelled again on every lookup. Open addressing over parallel arrays, linear probing, never
 * more than half full.
 */
class SemanticTypeMap<V> {
	var keys:Array<Null<CompilerType>>;
	var values:Array<Null<V>>;
	var hashes:Array<Int>;
	var count = 0;

	public function new()
		allocate(16);

	public function get(type:CompilerType):Null<V> {
		var slot = find(type, hash(type));
		return slot >= 0 ? values[slot] : null;
	}

	public function set(type:CompilerType, value:V):Void {
		var code = hash(type), slot = find(type, code);
		if (slot >= 0) {
			values[slot] = value;
			return;
		}
		if ((count + 1) * 2 > keys.length)
			grow();
		insert(type, code, value);
	}

	public function clear():Void {
		allocate(16);
		count = 0;
	}

	function find(type:CompilerType, code:Int):Int {
		var mask = keys.length - 1, slot = code & mask;
		while (true) {
			var key = keys[slot];
			if (key == null)
				return -1;
			if (hashes[slot] == code && same(key, type))
				return slot;
			slot = (slot + 1) & mask;
		}
	}

	function insert(type:CompilerType, code:Int, value:V):Void {
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

	/**
	 * Whether `left` and `right` have the same `SemanticSignature.type` spelling, compared part by part as `spell` writes them:
	 * a filled type variable is its type, an abstract is its name and arguments, a closed structure its name. An open
	 * structure has no spelling yet, as `spell` reports.
	 */
	public static function same(left:CompilerType, right:CompilerType):Bool {
		left = filled(left);
		right = filled(right);
		if (tag(left) != tag(right))
			return false;
		return switch left {
			case TNativeAbstract(a): a == (switch right {
					case TNativeAbstract(b): b;
					default: null;
				});
			case TNativeScalar(a): a == (switch right {
					case TNativeScalar(b): b;
					default: null;
				});
			case TTypeParameter(ownerA, a):
				switch right {
					case TTypeParameter(ownerB, b): ownerA == ownerB && a == b;
					default: false;
				}
			case TAbstract(a, argumentsA, _):
				switch right {
					case TAbstract(b, argumentsB, _): a == b && sameAll(argumentsA, argumentsB);
					default: false;
				}
			case TInstance(kindA, a, argumentsA):
				switch right {
					case TInstance(kindB, b, argumentsB): kindA == kindB && a == b && sameAll(argumentsA, argumentsB);
					default: false;
				}
			case TNullable(a), TArray(a), TIterator(a):
				switch right {
					case TNullable(b), TArray(b), TIterator(b): same(a, b);
					default: false;
				}
			case TMap(keyA, valueA):
				switch right {
					case TMap(keyB, valueB): same(keyA, keyB) && same(valueA, valueB);
					default: false;
				}
			case TKeyPath(rootA, valueA, writableA):
				switch right {
					case TKeyPath(rootB, valueB, writableB): writableA == writableB && same(rootA, rootB)
						&& same(valueA, valueB);
					default: false;
				}
			case TFunction(argumentsA, resultA, optionalA):
				switch right {
					case TFunction(argumentsB, resultB, optionalB):
						if (argumentsA.length != argumentsB.length || !same(resultA, resultB))
							return false;
						for (index in 0...argumentsA.length)
							if (FunctionTypes.isOptional(optionalA, index) != FunctionTypes.isOptional(optionalB, index)
								|| !same(argumentsA[index], argumentsB[index]))
								return false;
						true;
					default: false;
				}
			case TAnonymous(a, _):
				switch right {
					case TAnonymous(b, _): closedName(a) == closedName(b);
					default: false;
				}
			case TMonomorph(a):
				switch right {
					case TMonomorph(b): a.origin == b.origin;
					default: false;
				}
			// The other constructors carry nothing: the same tag is the same type.
			default: true;
		};
	}

	static function sameAll(left:Array<CompilerType>, right:Array<CompilerType>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!same(left[index], right[index]))
				return false;
		return true;
	}

	/** A hash of the type's spelling identity, consistent with `same`. */
	public static function hash(type:CompilerType):Int {
		type = filled(type);
		var code = mix(tag(type));
		return mix(switch type {
			case TNativeAbstract(name), TNativeScalar(name): code ^ text(name);
			case TTypeParameter(owner, name): mix(code ^ text(owner)) ^ text(name);
			case TAbstract(name, arguments, _), TInstance(_, name, arguments):
				code ^= text(name);
				for (argument in arguments)
					code = mix(code) ^ hash(argument);
				code;
			case TNullable(element), TArray(element), TIterator(element): code ^ hash(element);
			case TMap(key, value), TKeyPath(key, value, _): mix(code ^ hash(key)) ^ hash(value);
			case TFunction(arguments, result, optional):
				code ^= hash(result);
				for (index in 0...arguments.length)
					code = mix(code + (FunctionTypes.isOptional(optional, index) ? 1 : 0)) ^ hash(arguments[index]);
				code;
			case TAnonymous(name, _): code ^ text(closedName(name));
			case TMonomorph(cell): code ^ text(cell.origin);
			default: code;
		});
	}

	/** The constructor, with a nominal kind and a key path's writability, which `spell` writes as part of the name. */
	static function tag(type:CompilerType):Int
		return switch type {
			case TInt: 1;
			case TInt64: 2;
			case TBool: 3;
			case TFloat: 4;
			case TString: 5;
			case TBytes: 6;
			case THlBytes: 7;
			case TDynamic: 8;
			case TNativeAbstract(_): 9;
			case TNativeScalar(_): 10;
			case TNever: 11;
			case TRange: 12;
			case TVoid: 13;
			case TTypeParameter(_, _): 14;
			case TAbstract(_, _, _): 15;
			case TInstance(kind, _, _): switch kind {
					case NominalKind.Class: 16;
					case NominalKind.Interface: 17;
					case NominalKind.Enum: 18;
					case NominalKind.NativeValue: 19;
					default: throw new InternalError('Unknown nominal kind $kind');
				}
			case TNull: 20;
			case TNullable(_): 21;
			case TArray(_): 22;
			case TIterator(_): 23;
			case TMap(_, _): 24;
			case TKeyPath(_, _, writable): writable ? 26 : 25;
			case TFunction(_, _, _): 27;
			case TAnonymous(_, _): 28;
			case TMonomorph(_): 29;
		};

	/** A filled type variable's type, followed through chains, as `spell` follows it. */
	static function filled(type:CompilerType):CompilerType {
		while (true)
			switch type {
				case TMonomorph(cell) if (cell.bound != null): type = cell.bound;
				default: return type;
			}
	}

	static function closedName(name:String):String {
		if (compiler.types.Monomorphs.isOpenStructureName(name))
			throw new InternalError('An open literal structure ($name) was spelled before its unit closed it');
		return name;
	}

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
