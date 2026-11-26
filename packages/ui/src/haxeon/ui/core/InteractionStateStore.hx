package haxeon.ui.core;

import haxeon.ui.style.StyleState;

/** Persistent generic input flags, with native fields and reusable pending records. */
class InteractionStateStore implements Disposable {
	final values:Map<Int, InteractionChange> = new Map();
	final pending:Array<InteractionChange> = [];
	var pendingCount:Int = 0;
	/** Borrowed until the next state change or acknowledge. */
	final changeScratch:Array<InteractionChange> = [];
	var changesRevision:Int = -1;

	/** Counts the changes, so a cache can tell whether any widget's state changed. */
	public var revision(default, null):Int = 0;

	/** No widget hovered, pressed or focused. */
	public function new() {}

	/** The widget `id`'s interaction states: hovered, pressed, focused and the like. */
	public function get(id:WidgetId):StyleState {
		if (id == null) return StyleState.empty();
		var value = values.get(id.value);
		return value == null ? StyleState.empty() : value.after;
	}

	/** Sets the widget `id`'s interaction states, which its style then selects on. */
	public function set(id:WidgetId, value:StyleState):Void {
		if (id == null) throw "Interaction state requires a widget ID";
		var entry = values.get(id.value);
		if (entry == null) {
			if (value.isEmpty()) return;
			entry = new InteractionChange(id.value);
			values.set(id.value, entry);
		} else if (entry.after == value) return;
		if (!entry.pending) {
			entry.before = entry.after;
			entry.pending = true;
			if (pendingCount == pending.length) pending.push(entry);
			else pending[pendingCount] = entry;
			pendingCount++;
		}
		entry.after = value;
		revision++;
	}

	/** Net changes since submission; repeated edits preserve the transaction's original value. */
	internal function changes():Array<InteractionChange> {
		if (changesRevision == revision) return changeScratch;
		var count = 0;
		for (index in 0...pendingCount) {
			var entry = pending[index];
			if (entry.before == entry.after) continue;
			if (count == changeScratch.length) changeScratch.push(entry);
			else changeScratch[count] = entry;
			count++;
		}
		changeScratch.resize(count);
		changesRevision = revision;
		return changeScratch;
	}

	internal function acknowledge():Void {
		for (index in 0...pendingCount) pending[index].pending = false;
		pendingCount = 0;
		changeScratch.resize(0);
		changesRevision = revision;
	}

	public function dispose():Void {
		values.clear();
		pending.resize(0);
		pendingCount = 0;
		changeScratch.resize(0);
		revision++;
		changesRevision = revision;
	}
}

/** One record per observed identity, shared by stored input and borrowed change lists. */
@:allow(haxeon.ui.core.InteractionStateStore) internal class InteractionChange {
	public final id:Int;
	public var before(default, null):StyleState = StyleState.empty();
	public var after(default, null):StyleState = StyleState.empty();
	var pending:Bool = false;
	public function new(id:Int) this.id = id;

	/** Whether only the hover flag changed. */
	public inline function hoverOnly():Bool return ((before.rawValue ^ after.rawValue)
		& ~StyleState.Hovered.rawValue) == 0;
}
