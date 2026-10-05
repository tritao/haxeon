package nativekit.ui.core;

/** Haxe-owned per-widget state retained while views are rebuilt. */
class StateStore {
	final values:Map<Int, Dynamic>;
	// Store revision at each state's last update, so retained subtrees can tell which of their own states changed.
	final valueRevisions:Map<Int, Int> = new Map();
	final disposers:Map<Int, Void->Void>;
	final paths:Map<Int, String>;
	final managed:Map<Int, Bool>;
	final frameUsed:IdSet;
	/** Scratch for usedIdsSince, reused so collecting a subtree's states allocates only the result. */
	final seenScratch:IdSet = new IdSet(256);
	final frameUseOrder:Array<Int>;
	var frameActive:Bool;
	public var revision(default, null):Int;

	public function new() {
		values = new Map();
		disposers = new Map();
		paths = new Map();
		managed = new Map();
		frameUsed = new IdSet();
		frameUseOrder = [];
		frameActive = false;
		revision = 0;
	}

	/** Records the scoped key path used to make a widget ID for diagnostics. */
	public function rememberPath(id:WidgetId, path:String):Void {
		if (id != null && path != null && paths.get(id.value) != path)
			paths.set(id.value, path);
	}

	/** Keep diagnostic paths only for mounted nodes or retained application state. */
	public function prunePaths(mounted:Map<Int, RenderNode>):Void {
		var stale = [for (id in paths.keys()) if (!mounted.exists(id) && !values.exists(id)) id];
		for (id in stale) paths.remove(id);
	}

	public function initialize(id:WidgetId, initial:Dynamic):Void {
		if (id == null)
			throw "State requires a widget ID";
		if (!values.exists(id.value)) {
			values.set(id.value, initial);
		}
		markUsed(id);
	}

	/** Starts liveness tracking for resource-backed widget state. */
	public function beginFrame():Void {
		frameUsed.clear();
		frameUseOrder.resize(0);
		frameActive = true;
	}

	/** Returns a marker for state usage captured during the current frame. */
	public function usageMarker():Int
		return frameUseOrder.length;

	/** Returns state IDs first touched after a usage marker. */
	public function usedIdsSince(marker:Int):Array<Int> {
		var start = marker < 0 ? 0 : marker > frameUseOrder.length ? frameUseOrder.length : marker;
		var result:Array<Int> = [];
		seenScratch.clear();
		for (index in start...frameUseOrder.length) {
			var id = frameUseOrder[index];
			if (seenScratch.add(id))
				result.push(id);
		}
		return result;
	}

	/** Keeps state-backed resources for a retained, temporarily detached subtree. */
	public function retain(ids:Array<Int>):Void {
		if (ids == null)
			return;
		for (id in ids)
			if (values.exists(id))
				if (frameActive) {
					frameUsed.add(id);
					frameUseOrder.push(id);
				}
	}

	/** Marks an initialized state as used by the current render tree. */
	public function touch(id:WidgetId):Void {
		if (id == null || !values.exists(id.value))
			throw "Widget state has not been initialized";
		markUsed(id);
	}

	/** Releases resource-backed state that was absent from the completed tree. */
	public function endFrame():Void {
		if (!frameActive)
			return;
		var stale:Array<Int> = [];
		for (id in managed.keys())
			if (!frameUsed.has(id))
				stale.push(id);
		var failure:Dynamic = null;
		for (id in stale) {
			var disposer = disposers.get(id);
			try {
				if (disposer != null)
					disposer();
			} catch (error:Dynamic) {
				if (failure == null)
					failure = error;
			}
			disposers.remove(id);
			managed.remove(id);
			values.remove(id);
			valueRevisions.remove(id);
		}
		frameUsed.clear();
		frameUseOrder.resize(0);
		frameActive = false;
		if (stale.length > 0)
			revision++;
		if (failure != null)
			throw failure;
	}

	@:allow(nativekit.ui.core.State)
	function getValue(id:WidgetId):Dynamic {
		if (id == null || !values.exists(id.value))
			throw 'Widget state has not been initialized for ${describe(id)}';
		return values.get(id.value);
	}

	@:allow(nativekit.ui.core.State)
	function setValue(id:WidgetId, value:Dynamic):Void {
		if (id == null)
			throw "State requires a widget ID";
		values.set(id.value, value);
		revision++;
		valueRevisions.set(id.value, revision);
	}

	@:allow(nativekit.ui.core.State)
	function setValueQuietly(id:WidgetId, value:Dynamic):Void {
		if (id == null)
			throw "State requires a widget ID";
		values.set(id.value, value);
	}

	/** IDs of the states set after `since` (a value of `revision`), in no particular order. */
	public function idsChangedSince(since:Int):Array<Int> {
		var result:Array<Int> = [];
		for (id => changedAt in valueRevisions)
			if (changedAt > since)
				result.push(id);
		return result;
	}

	/** Revision at which this state last changed; zero if it never has been set since creation. */
	public function valueRevision(id:Int):Int {
		var result = valueRevisions.get(id);
		return result == null ? 0 : result;
	}

	public function contains(id:WidgetId):Bool
		return id != null && values.exists(id.value);

	/** Bounded-run diagnostics for detecting retained widget state growth. */
	public function diagnosticCounts():{values:Int, paths:Int, resources:Int} {
		var valueCount = 0;
		var pathCount = 0;
		var resourceCount = 0;
		for (_ in values.keys()) valueCount++;
		for (_ in paths.keys()) pathCount++;
		for (_ in managed.keys()) resourceCount++;
		return {values: valueCount, paths: pathCount, resources: resourceCount};
	}

	public function describe(id:WidgetId):String {
		if (id == null)
			return "null";
		var path = paths.get(id.value);
		return path == null ? Std.string(id.value) : Std.string(id.value) + " (" + path + ")";
	}

	/** Registers one native-resource cleanup callback for persistent widget state. */
	public function onDispose(id:WidgetId, disposer:Void->Void):Void {
		if (id == null || disposer == null || !values.exists(id.value) || disposers.exists(id.value))
			throw "State disposal requires initialized state and one callback per widget ID";
		disposers.set(id.value, disposer);
	}

	/** Registers a resource cleanup callback and enables per-frame liveness cleanup. */
	public function onUnmount(id:WidgetId, disposer:Void->Void):Void {
		onDispose(id, disposer);
		managed.set(id.value, true);
	}

	/** Releases registered widget resources and clears the store. */
	public function dispose():Void {
		var failure:Dynamic = null;
		for (id in disposers.keys()) {
			var disposer = disposers.get(id);
			try {
				disposer();
			} catch (error:Dynamic) {
				if (failure == null)
					failure = error;
			}
		}
		disposers.clear();
		managed.clear();
		frameUsed.clear();
		frameActive = false;
		values.clear();
		valueRevisions.clear();
		paths.clear();
		revision++;
		if (failure != null)
			throw failure;
	}

	function markUsed(id:WidgetId):Void {
		if (frameActive) {
			frameUsed.add(id.value);
			frameUseOrder.push(id.value);
		}
	}
}
