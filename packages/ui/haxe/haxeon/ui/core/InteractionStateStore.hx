package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Persistent generic interaction flags, separate from widget-owned values. */
class InteractionStateStore {
	final values:Map<Int, StyleState>;
	final pending:Map<Int, StyleState> = [];
	/** Borrowed until the next state change or acknowledge; reused by every caller in one input transaction. */
	final changeScratch:Array<{id:Int, before:StyleState, after:StyleState}> = [];
	var changesRevision:Int = -1;
	public var revision(default, null):Int;

	public function new() {
		values = new Map();
		revision = 0;
	}

	public function get(id:WidgetId):StyleState
		return id == null || !values.exists(id.value) ? StyleState.empty() : values.get(id.value);

	public function set(id:WidgetId, value:StyleState):Void {
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
	public function changes():Array<{id:Int, before:StyleState, after:StyleState}> {
		if (changesRevision == revision)
			return changeScratch;
		var count = 0;
		if (pending.size() != 0)
			for (id in pending.keys()) {
				if (!values.exists(id)) throw "Pending interaction change has no current state";
				var after:StyleState = values.get(id), before:StyleState = pending.get(id);
				if (before == after) continue;
				if (count == changeScratch.length)
					changeScratch.push({id:id, before:before, after:after});
				else {
					var change = changeScratch[count];
					change.id = id;
					change.before = before;
					change.after = after;
				}
				count++;
		}
		changeScratch.resize(count);
		changesRevision = revision;
		return changeScratch;
	}
	public function acknowledge():Void {
		pending.clear();
		changeScratch.resize(0);
		changesRevision = revision;
	}

	public function dispose():Void {
		values.clear();
		pending.clear();
		changeScratch.resize(0);
		revision++;
		changesRevision = revision;
	}
}
