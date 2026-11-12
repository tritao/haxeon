package haxeon.ui.core;

/** Haxe-owned per-widget state retained while views are rebuilt. */
class StateStore {
	final handles:Map<Int, State<Dynamic>> = new Map();
	/** A native scope is its own lifetime record, rather than a signal-valued state wrapper. */
	final scopes:Map<Int, RenderScope> = new Map();
	/** Resource ownership follows the current body, rather than a cache's initial flattened ID list. */
	final ownedStates:Map<Int, Array<Int>> = new Map();

	public function setOwnedStates(owner:Int, ids:Null<Array<Int>>):Void {
		if (ids == null) ownedStates.remove(owner);
		else ownedStates.set(owner, ids);
	}
	public function ownedStateIds(owner:Int):Null<Array<Int>> return ownedStates.get(owner);
	final disposers:Map<Int, Void->Void>;
	final paths:Map<Int, String>;
	/** The IDs in `paths`, oldest first, so a prune can walk them in place instead of snapshotting the map's keys. */
	final pathIds:Array<Int> = [];
	final managed:IdSet;
	/** Stable membership avoids copying all managed IDs on each frame. */
	final managedIds:Array<Int> = [for (_ in 0...256) 0];
	var managedCount:Int = 0;
	/** Reuse the normal cleanup worklist; nested cleanup gets its own list. */
	final staleScratch:Array<Int> = [];
	var sweeping:Bool = false;
	final frameUsed:IdSet;
	/** Scratch for usedIdsSince, reused so collecting a subtree's states allocates only the result. */
	final seenScratch:IdSet = new IdSet(256);
	final frameUseOrder:Array<Int>;
	var frameUseCount:Int = 0;
	public var frameActive(default, null):Bool;

	public function new() {
		disposers = new Map();
		paths = new Map();
		managed = new IdSet(256);
		frameUsed = new IdSet();
		frameUseOrder = [for (_ in 0...256) 0];
		frameActive = false;
	}

	@:allow(haxeon.ui.core.BuildContext)
	function handle<T>(id:WidgetId):State<T> {
		var result = handles.get(id.value);
		if (result == null)
			throw 'Widget state has not been initialized for ${describe(id)}';
		return cast result;
	}

	/** Resolve hash collisions without aliasing state belonging to another scoped path. */
	public function resolveWidgetId(path:String):WidgetId {
		var value = KeyScope.widgetIdForPath(path).value;
		while (paths.exists(value) && paths.get(value) != path)
			value = value == 0x7fffffff ? 1 : value + 1;
		var id = new WidgetId(value);
		rememberPath(id, path);
		return id;
	}

	/** Records the scoped key path used to make a widget ID for diagnostics. */
	public function rememberPath(id:WidgetId, path:String):Void {
		if (id != null && path != null) {
			var known = paths.get(id.value);
			if (known != path) {
				if (known == null)
					pathIds.push(id.value);
				paths.set(id.value, path);
			}
		}
	}

	/** Keep diagnostic paths only for mounted nodes or retained application state. */
	public function prunePaths(mounted:Map<Int, RenderNode>):Void {
		var read = 0, write = 0;
		while (read < pathIds.length) {
			var id = pathIds[read++];
			if (!paths.exists(id))
				continue;
			if (!mounted.exists(id) && !handles.exists(id) && !scopes.exists(-id))
				paths.remove(id);
			else
				pathIds[write++] = id;
		}
		pathIds.resize(write);
	}

	public function initialize<T>(id:WidgetId, initial:T):Void {
		if (id == null)
			throw "State requires a widget ID";
		if (scopes.exists(id.value)) throw "A native scope already owns this resource ID";
		if (!handles.exists(id.value))
			handles.set(id.value, new State<T>(this, id, initial));
		markUsed(id);
	}

	/** Mark the logical scope resource before its body captures descendant resource usage. */
	public function beginScope(id:Int):Void {
		if (id >= 0 || handles.exists(id)) throw "Native scope resource has a different owner type";
		markUsedValue(id);
	}

	public function scopeOwner(id:Int):Null<RenderScope> return scopes.get(id);

	/** A successful body installs one native owner and releases its previous computation. */
	public function installScope(owner:RenderScope):Void {
		var id = owner.resourceId;
		if (handles.exists(id)) throw "Native scope resource has a different owner type";
		var previous = scopes.get(id);
		if (previous != null && previous != owner) previous.dispose();
		scopes.set(id, owner);
		if (!managed.has(id)) {
			managed.add(id);
			appendManaged(id);
		}
	}

	/** Starts liveness tracking for resource-backed widget state. */
	public function beginFrame():Void {
		frameUsed.clear();
		frameUseCount = 0;
		frameActive = true;
	}

	/** Returns a marker for state usage captured during the current frame. */
	public function usageMarker():Int
		return frameUseCount;

	/** Returns state IDs first touched after a usage marker. */
	public function usedIdsSince(marker:Int, ?previous:Array<Int>):Array<Int> {
		var start = marker < 0 ? 0 : marker > frameUseCount ? frameUseCount : marker;
		var count = 0, same = previous != null;
		seenScratch.clear();
		for (index in start...frameUseCount) {
			var id = frameUseOrder[index];
			if (!seenScratch.add(id)) continue;
			if (previous == null || count >= previous.length || previous[count] != id) same = false;
			count++;
		}
		if (previous != null && same && previous.length == count) return previous;
		var result:Array<Int> = [];
		result.resize(count);
		seenScratch.clear();
		var position = 0;
		for (index in start...frameUseCount) {
			var id = frameUseOrder[index];
			if (seenScratch.add(id)) result[position++] = id;
		}
		return result;
	}

	/** Finish an independently retained build without copying its state reads into its enclosing cache. */
	var usageCaptures:Int = 0;
	public function beginUsage():Int {
		usageCaptures++;
		return frameUseCount;
	}
	public function finishUsage(marker:Int):Void {
		frameUseCount = marker;
		usageCaptures--;
	}

	/** Keeps state-backed resources for a retained, temporarily detached subtree. */
	public function retain(ids:Array<Int>, recordUsage:Bool = true):Void {
		if (ids == null)
			return;
		for (id in ids)
			if (handles.exists(id) || scopes.exists(id)) {
				if (frameActive) frameUsed.add(id);
				if (recordUsage && (frameActive || usageCaptures > 0)) appendUsage(id);
				var children = ownedStates.get(id);
				if (children != null) retain(children, false);
			}
	}

	/** Marks an initialized state as used by the current render tree. */
	public function touch(id:WidgetId):Void {
		if (id == null || !contains(id))
			throw "Widget state has not been initialized";
		markUsed(id);
		var children = ownedStates.get(id.value);
		if (children != null) retain(children, false);
	}

	public function touchScope(id:Int):Void {
		if (!scopes.exists(id)) throw "Native scope has not been initialized";
		markUsedValue(id);
		var children = ownedStates.get(id);
		if (children != null) retain(children, false);
	}

	@:allow(haxeon.ui.core.State)
	function check(id:WidgetId):Void {
		if (id == null || !handles.exists(id.value))
			throw 'Widget state has not been initialized for ${describe(id)}';
	}

	/** Releases resource-backed state that was absent from the completed tree. */
	public function endFrame():Void {
		if (!frameActive)
			return;
		var nested = sweeping;
		var stale:Array<Int> = nested ? [] : staleScratch;
		stale.resize(0);
		sweeping = true;
		for (index in 0...managedCount) {
			var id = managedIds[index];
			if (!frameUsed.has(id)) stale.push(id);
		}
		var failure:Dynamic = null;
		for (id in stale) {
			var disposer = disposers.get(id);
			try {
				var owner = scopes.get(id);
				if (owner != null) owner.dispose();
				if (disposer != null)
					disposer();
			} catch (error:Dynamic) {
				if (failure == null)
					failure = error;
			}
			disposers.remove(id);
			managed.remove(id);
			handles.remove(id);
			scopes.remove(id);
			ownedStates.remove(id);
		}
		if (stale.length > 0) {
			var read = 0, write = 0;
			seenScratch.clear();
			while (read < managedCount) {
				var id = managedIds[read++];
				// A later disposer can recreate an earlier ID while this sweep is in progress.
				if (managed.has(id) && seenScratch.add(id)) managedIds[write++] = id;
			}
			managedCount = write;
		}
		stale.resize(0);
		sweeping = nested;
		frameUsed.clear();
		frameUseCount = 0;
		frameActive = false;
		if (failure != null)
			throw failure;
	}

	public function contains(id:WidgetId):Bool
		return id != null && (handles.exists(id.value) || scopes.exists(id.value));

	/** Bounded-run diagnostics for detecting retained widget state growth. */
	public function diagnosticCounts():{values:Int, paths:Int, resources:Int} {
		var valueCount = 0;
		var pathCount = 0;
		var resourceCount = 0;
		for (_ in handles.keys()) valueCount++;
		for (_ in scopes.keys()) valueCount++;
		for (_ in paths.keys()) pathCount++;
		resourceCount = managed.count();
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
		if (id == null || disposer == null || !handles.exists(id.value) || disposers.exists(id.value))
			throw "State disposal requires initialized state and one callback per widget ID";
		disposers.set(id.value, disposer);
	}

	/** Registers a resource cleanup callback and enables per-frame liveness cleanup. */
	public function onUnmount(id:WidgetId, disposer:Void->Void):Void {
		onDispose(id, disposer);
		managed.add(id.value);
		appendManaged(id.value);
	}

	/** Releases registered widget resources and clears the store. */
	public function dispose():Void {
		var failure:Dynamic = null;
		for (index in 0...managedCount) {
			var id = managedIds[index];
			var owner = scopes.get(id);
			try {
				if (owner != null) owner.dispose();
			} catch (error:Dynamic) {
				if (failure == null) failure = error;
			}
		}
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
		managedCount = 0;
		frameUsed.clear();
		frameActive = false;
		handles.clear();
		scopes.clear();
		ownedStates.clear();
		paths.clear();
		pathIds.resize(0);
		if (failure != null)
			throw failure;
	}

	function appendManaged(id:Int):Void {
		if (managedCount == managedIds.length) managedIds.resize(managedIds.length * 2);
		managedIds[managedCount++] = id;
	}

	/** Logical length is independent of capacity, including nested usage captures. */
	function appendUsage(id:Int):Void {
		if (frameUseCount == frameUseOrder.length) frameUseOrder.resize(frameUseOrder.length * 2);
		frameUseOrder[frameUseCount++] = id;
	}

	function markUsed(id:WidgetId):Void markUsedValue(id.value);

	function markUsedValue(id:Int):Void {
		if (frameActive) frameUsed.add(id);
		if (frameActive || usageCaptures > 0) appendUsage(id);
	}
}
