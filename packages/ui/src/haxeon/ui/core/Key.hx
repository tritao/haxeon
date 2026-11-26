package haxeon.ui.core;

import haxe.io.Bytes;

/** Caller-chosen stable key; the validated string is the complete identity value. */
abstract Key(String) {
	/** A key for `value`, which identifies a widget among its siblings. Throws when it is empty. */
	public inline function new(value:String) {
		if (value == null || value.length == 0) throw "Widget keys must not be empty";
		this = value;
	}

	/** The key as text. */
	public inline function rawValue():String return this;
}

/** Length-prefixed key path with deterministic UTF-8 hashing. */
class KeyScope {
	final path:String;
	final root:KeyScope;
	var children:Null<Map<String, KeyScope>>;
	var widgetPaths:Null<Map<String, String>>;
	// Dense lists let pruning visit retained entries without map iterator snapshots.
	var childScopes:Null<Array<KeyScope>>;
	var widgetKeys:Null<Array<String>>;
	var childKey:String = "";
	var entries:Int;

	/** The scope at `path`; a build starts from the root scope, and `child` makes the deeper ones. */
	public function new(path:String = "", ?root:KeyScope) {
		this.path = path;
		this.root = root == null ? this : root;
		entries = 0;
	}

	/** The scope `key` names within this one, made once and reused. */
	public function child(key:Key):KeyScope {
		if (key == null) throw "A key scope requires a key";
		if (children == null) {
			children = new Map();
			childScopes = [];
		}
		var cached = children.get(key.rawValue());
		if (cached != null) return cached;
		var result = new KeyScope(path + key.rawValue().length + ":" + key.rawValue() + "|", root);
		result.childKey = key.rawValue();
		children.set(key.rawValue(), result);
		childScopes.push(result);
		root.entries++;
		return result;
	}

	/** The id of the widget `localKey` names in this scope: the same in every build, so its state and focus survive. */
	public function widgetId(localKey:String):WidgetId {
		return widgetIdForPath(widgetPath(localKey));
	}

	/** Reuses the exact scoped path for hashing and diagnostic identity. */
	public function widgetPath(localKey:String):String {
		if (localKey == null || localKey.length == 0) throw "Local widget keys must not be empty";
		if (widgetPaths == null) {
			widgetPaths = new Map();
			widgetKeys = [];
		}
		var cached = widgetPaths.get(localKey);
		if (cached != null) return cached;
		var result = path + localKey.length + ":" + localKey;
		widgetPaths.set(localKey, result);
		widgetKeys.push(localKey);
		root.entries++;
		return result;
	}

	/** Number of retained child scopes and widget paths in this scope tree. */
	public inline function cachedEntries():Int return root.entries;

	/** Discard cached paths for unmounted widgets; IDs remain deterministic on remount. */
	public function prune(keep:String->Bool):Bool {
		var live = false;
		var keys = widgetKeys;
		if (widgetPaths != null && keys != null) {
			var read = 0, write = 0;
			while (read < keys.length) {
				var key = keys[read++];
				if (keep(widgetPaths.get(key))) {
					live = true;
					keys[write++] = key;
				} else {
					widgetPaths.remove(key);
					root.entries--;
				}
			}
			keys.resize(write);
		}
		var scopes = childScopes;
		if (children != null && scopes != null) {
			var read = 0, write = 0;
			while (read < scopes.length) {
				var child = scopes[read++];
				if (child.prune(keep)) {
					live = true;
					scopes[write++] = child;
				} else {
					children.remove(child.childKey);
					root.entries--;
				}
			}
			scopes.resize(write);
		}
		return live;
	}

	internal static function widgetIdForPath(fullPath:String):WidgetId {
		var bytes = Bytes.ofString(fullPath);
		var hash = -2128831035;
		for (index in 0...bytes.length) hash = (hash ^ bytes.get(index)) * 16777619;
		var value = hash & 0x7fffffff;
		return new WidgetId(value == 0 ? 1 : value);
	}

	internal inline function pathValue():String return path;
}

/**
 * Accumulates a cache key from numbers and strings without building a string. Two 32-bit lanes with different mixing
 * make an accidental match between two different keys about as unlikely as a 64-bit hash collision. Reuse one instance
 * with `reset`: nothing here allocates. Floats count to a resolution of 2^-24.
 */
internal class KeyHash {
	static inline var SeedA = 0x811c9dc5;
	static inline var SeedB = 0x2545f491;
	static inline var PrimeA = 16777619;

	public var a(default, null):Int = SeedA;
	public var b(default, null):Int = SeedB;

	public function new() {}

	public function reset():KeyHash {
		a = SeedA;
		b = SeedB;
		return this;
	}

	public function addInt(value:Int):KeyHash {
		a = (a ^ value) * PrimeA;
		b ^= value + 0x9e3779b9 + (b << 6) + (b >>> 2);
		return this;
	}

	public function addBool(value:Bool):KeyHash
		return addInt(value ? 1 : 0);

	public function addFloat(value:Float):KeyHash {
		if (value != value)
			return addInt(0x7fc00000);
		if (value >= 2147483647.0)
			return addInt(2147483647).addInt(1);
		if (value <= -2147483647.0)
			return addInt(-2147483647).addInt(-1);
		var whole = Std.int(value);
		return addInt(whole).addInt(Std.int((value - whole) * 16777216.0));
	}

	/** The length goes in first, so ("ab", "c") and ("a", "bc") differ. */
	public function addString(value:Null<String>):KeyHash {
		if (value == null)
			return addInt(-1);
		var length = value.length;
		addInt(length);
		for (index in 0...length)
			addInt(StringTools.fastCodeAt(value, index));
		return this;
	}
}
