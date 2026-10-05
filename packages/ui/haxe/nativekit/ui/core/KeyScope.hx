package nativekit.ui.core;

import haxe.io.Bytes;

/** Length-prefixed key path with deterministic UTF-8 hashing. */
class KeyScope {
	final path:String;
	final root:KeyScope;
	var children:Null<Map<String, KeyScope>>;
	var widgetPaths:Null<Map<String, String>>;
	var entries:Int;

	public function new(path:String = "", ?root:KeyScope) {
		this.path = path;
		this.root = root == null ? this : root;
		entries = 0;
	}

	public function child(key:Key):KeyScope {
		if (key == null)
			throw "A key scope requires a key";
		if (children == null)
			children = new Map();
		var cached = children.get(key.value);
		if (cached != null)
			return cached;
		var result = new KeyScope(path + key.value.length + ":" + key.value + "|", root);
		children.set(key.value, result);
		root.entries++;
		return result;
	}

	public function widgetId(localKey:String):WidgetId {
		return widgetIdForPath(widgetPath(localKey));
	}

	/** Reuses the exact scoped path for hashing and diagnostic identity. */
	public function widgetPath(localKey:String):String {
		if (localKey == null || localKey.length == 0)
			throw "Local widget keys must not be empty";
		if (widgetPaths == null)
			widgetPaths = new Map();
		var cached = widgetPaths.get(localKey);
		if (cached != null)
			return cached;
		var result = path + localKey.length + ":" + localKey;
		widgetPaths.set(localKey, result);
		root.entries++;
		return result;
	}

	/** Number of retained child scopes and widget paths in this scope tree. */
	public inline function cachedEntries():Int
		return root.entries;

	public static function widgetIdForPath(fullPath:String):WidgetId {
		var bytes = Bytes.ofString(fullPath);
		var hash = -2128831035;
		for (index in 0...bytes.length)
			hash = (hash ^ bytes.get(index)) * 16777619;
		var value = hash & 0x7fffffff;
		return new WidgetId(value == 0 ? 1 : value);
	}

	public inline function pathValue():String
		return path;
}
