package haxeon.ui.core;

import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveRuntime;
import haxeon.ui.style.StyleState;

/**
 * Each widget's routed input states (hovered, pressed, focused), as reactive sources. A build that reads a widget's states
 * depends on the ones it read, so a change wakes exactly those readers; the store also keeps the net changes since the last
 * submission for the parts of the tree that are not components yet.
 */
class InteractionStateStore implements Disposable {
	/** Every state a widget can have. */
	public static final Every:StyleState = StyleState.Hovered | StyleState.Pressed | StyleState.Focused
		| StyleState.Disabled | StyleState.Selected | StyleState.Checked;

	final values:Map<Int, InteractionEntry> = new Map();
	var count:Int = 0;
	/** How many entries there were after the last prune: reads add entries for widgets with no state. */
	var prunedCount:Int = 0;
	final pending:Array<InteractionEntry> = [];
	var pendingCount:Int = 0;
	/** Borrowed until the next state change or acknowledge. */
	final changeScratch:Array<InteractionEntry> = [];
	var changesRevision:Int = -1;

	/** Counts the changes, so a cache can tell whether any widget's state changed. */
	public var revision(default, null):Int = 0;

	/** No widget hovered, pressed or focused. */
	public function new() {}

	/** The widget `id`'s states; a build that calls this depends on all of them. */
	public function get(id:WidgetId):StyleState return read(id, Every);

	/**
	 * The widget `id`'s states, of which a build that calls this depends only on `dependsOn`. The others are returned to be
	 * recorded, as on `RenderNode.states`, which routing keeps current without a rebuild.
	 */
	public function read(id:WidgetId, dependsOn:StyleState):StyleState {
		if (id == null) return StyleState.empty();
		var entry = values.get(id.value);
		if (dependsOn.isEmpty() || !ReactiveRuntime.isTracking())
			return entry == null ? StyleState.empty() : entry.after;
		if (entry == null) entry = add(id.value);
		for (field in 0...InteractionEntry.FieldCount) if ((dependsOn.rawValue
			& InteractionEntry.fieldStates(field).rawValue) != 0) entry.recordFieldRead(field);
		return entry.after;
	}

	/** The widget `id`'s states, without depending on them. */
	public function peek(id:WidgetId):StyleState {
		if (id == null) return StyleState.empty();
		var entry = values.get(id.value);
		return entry == null ? StyleState.empty() : entry.after;
	}

	/** Sets the widget `id`'s states, waking the builds that read the ones that changed. */
	public function set(id:WidgetId, value:StyleState):Void {
		if (id == null) throw "Interaction state requires a widget ID";
		var entry = values.get(id.value);
		if (entry == null) {
			if (value.isEmpty()) return;
			entry = add(id.value);
		} else if (entry.after == value) return;
		if (!entry.pending) {
			entry.before = entry.after;
			entry.pending = true;
			if (pendingCount == pending.length) pending.push(entry);
			else pending[pendingCount] = entry;
			pendingCount++;
		}
		var changed = entry.after.rawValue ^ value.rawValue;
		entry.after = value;
		revision++;
		for (field in 0...InteractionEntry.FieldCount)
			if ((changed & InteractionEntry.fieldStates(field).rawValue) != 0) entry.invalidateField(field);
	}

	function add(id:Int):InteractionEntry {
		var entry = new InteractionEntry(id);
		values.set(id, entry);
		count++;
		return entry;
	}

	/** Net changes since submission; repeated edits preserve the transaction's original value. */
	internal function changes():Array<InteractionEntry> {
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
		if (count > prunedCount * 2 + 64) prune();
	}

	/** Drops the entries nothing reads and no state is set on. */
	function prune():Void {
		var unused:Array<Int> = [];
		for (entry in values) if (entry.after.isEmpty() && !entry.hasReaders()) unused.push(entry.id);
		for (id in unused) values.remove(id);
		count -= unused.length;
		prunedCount = count;
	}

	public function dispose():Void {
		values.clear();
		count = 0;
		prunedCount = 0;
		pending.resize(0);
		pendingCount = 0;
		changeScratch.resize(0);
		revision++;
		changesRevision = revision;
	}
}

/** One widget's states: the reactive source its readers subscribe to, and its pending change in this frame. */
@:allow(haxeon.ui.core.InteractionStateStore) internal class InteractionEntry extends ObservableSource {
	public static inline var FieldCount = 4;

	static final Authored:StyleState = StyleState.Disabled | StyleState.Selected | StyleState.Checked;

	/** The states each field covers: one per routed state, then the authored ones together. */
	public static inline function fieldStates(field:Int):StyleState {
		return field == 0 ? StyleState.Hovered : field == 1 ? StyleState.Pressed : field == 2
			? StyleState.Focused : Authored;
	}

	public final id:Int;
	public var before(default, null):StyleState = StyleState.empty();
	public var after(default, null):StyleState = StyleState.empty();
	var pending:Bool = false;

	public function new(id:Int) {
		super(FieldCount);
		this.id = id;
	}

	/** Whether only the hover flag changed. */
	public inline function hoverOnly():Bool return ((before.rawValue ^ after.rawValue)
		& ~StyleState.Hovered.rawValue) == 0;

	function hasReaders():Bool {
		for (field in 0...FieldCount) if (hasFieldReaders(field)) return true;
		return false;
	}
}
