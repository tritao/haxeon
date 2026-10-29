package haxeon.ui.core;

/** Persistent generic interaction flags, separate from widget-owned values. */
class InteractionStateStore {
	final values:Map<Int, Int>;
	final pending:Map<Int, Int> = [];
	public var revision(default, null):Int;

	public function new() {
		values = new Map();
		revision = 0;
	}

	public function get(id:WidgetId):Int
		return id == null || !values.exists(id.value) ? 0 : values.get(id.value);

	public function set(id:WidgetId, value:Int):Void {
		if (id == null)
			throw "Interaction state requires a widget ID";
		var previous = get(id);
		if (previous == value)
			return;
		if (!pending.exists(id.value)) pending.set(id.value, previous);
		values.set(id.value, value);
		revision++;
	}

	/** Net state changes since the last submitted frame, bounded by touched widget IDs. */
	public function changes():Array<{id:Int, before:Int, after:Int}> {
		var result = [];
		for (id in pending.keys()) {
			var before:Int = cast pending.get(id), after:Int = cast values.get(id);
			if (before != after) result.push({id:id, before:before, after:after});
		}
		return result;
	}
	public function acknowledge():Void pending.clear();

	public function dispose():Void {
		values.clear();
		pending.clear();
		revision++;
	}
}
