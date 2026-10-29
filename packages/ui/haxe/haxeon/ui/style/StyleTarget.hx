package haxeon.ui.style;

/** Style-facing identity and interaction data for one render node. */
class StyleTarget {
	public final widgetType:String;
	public final key:Null<String>;
	public final id:Null<String>;
	public final classes:Array<String>;
	public final tags:Array<String>;
	public final states:Int;
	/** Hash of the selector inputs other than pseudo-state, computed without allocating. */
	public final selectorHash:Int;
	/** Shared by every target without classes or tags; never mutated. */
	static final NoStrings:Array<String> = [];
	static final interned:Map<String, Array<String>> = new Map();
	static var internedCount = 0;
	static inline var MaxInterned = 512;

	/**
	 * An array of class or tag names that nobody will mutate. The common one-name array is shared by every node that uses
	 * it, so a widget's `["row"]` costs no copy per node; anything else is copied. Style identity arrays are only ever read.
	 */
	public static function shared(values:Null<Array<String>>):Array<String> {
		if (values == null || values.length == 0)
			return NoStrings;
		if (values.length == 1) {
			var name = values[0];
			if (name != null) {
				var known = interned.get(name);
				if (known != null)
					return known;
				if (internedCount < MaxInterned) {
					var copy = values.copy();
					interned.set(name, copy);
					internedCount++;
					return copy;
				}
			}
		}
		return values.copy();
	}

	public function new(widgetType:String, ?key:String, ?id:String,
			?classes:Array<String>, ?tags:Array<String>, states:Int = 0) {
		if (widgetType == null || widgetType.length == 0)
			throw "Style targets require a widget type";
		this.widgetType = widgetType;
		this.key = key;
		this.id = id;
		this.classes = shared(classes);
		this.tags = shared(tags);
		this.states = states;
		var hash = hashString(widgetType, -2128831035);
		hash = hashString(key, hash * 31 + 1);
		hash = hashString(id, hash * 31 + 2);
		hash = hashValues(this.classes, hash * 31 + 3);
		selectorHash = hashValues(this.tags, hash * 31 + 4);
	}

	/** Whether both targets select on identical type, key, id, classes and tags (pseudo-state excluded). */
	public function sameSelector(other:StyleTarget):Bool
		return this == other || (widgetType == other.widgetType && key == other.key && id == other.id &&
			sameValues(classes, other.classes) && sameValues(tags, other.tags));

	/** Stable text form of the selector inputs, for diagnostics; the style cache compares structurally instead. */
	public var selectorFingerprint(get, never):String;

	function get_selectorFingerprint():String
		return stringKey(widgetType) + "|key=" + stringKey(key) + "|id=" + stringKey(id) +
			"|classes=" + valuesKey(classes) + "|tags=" + valuesKey(tags);

	static function hashString(value:Null<String>, seed:Int):Int {
		if (value == null)
			return seed * 16777619 + 0x9e3779b;
		var hash = seed;
		for (index in 0...value.length)
			hash = (hash ^ StringTools.fastCodeAt(value, index)) * 16777619;
		return hash ^ value.length;
	}

	static function hashValues(values:Array<String>, seed:Int):Int {
		var hash = seed * 16777619 + values.length;
		for (value in values)
			hash = hashString(value, hash);
		return hash;
	}

	static function sameValues(left:Array<String>, right:Array<String>):Bool {
		if (left == right)
			return true;
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function valuesKey(values:Array<String>):String {
		var result = values.length + ":";
		for (value in values)
			result += stringKey(value) + ";";
		return result;
	}

	static function stringKey(value:Null<String>):String
		return value == null ? "-1:" : value.length + ":" + value;

	public function hasState(state:StyleState):Bool
		return StyleStateUtil.contains(states, state);

	public function hasClass(name:String):Bool
		return contains(classes, name);

	public function hasTag(name:String):Bool
		return contains(tags, name);

	static function contains(values:Array<String>, value:String):Bool {
		if (value == null)
			return false;
		for (present in values)
			if (present == value)
				return true;
		return false;
	}
}
