package haxeon.ui.core;

/** Haxe-owned per-widget state retained while views are rebuilt. */
class StateStore {
  final handles:Map<Int, State<Dynamic>> = new Map();
  /** A native scope is its own lifetime record, rather than a signal-valued state wrapper. */
  final scopes:Map<ScopeResourceId, RenderScope> = new Map();
  // A cached alternative owns its component instances even when their widget IDs match the visible alternative.
  var nextScopeId:Int = 1;
  final retainedWidgetScratch:IdSet = new IdSet(256);

  /** Resource ownership follows the current body, rather than a cache's initial flattened ID list. */
  final ownedStates:Map<ResourceId, Array<ResourceId>> = new Map();

  public function setOwnedStates(owner:ResourceId, ids:Null<Array<ResourceId>>):Void {
    if (ids == null) ownedStates.remove(owner);
    else ownedStates.set(owner, ids);
  }
  public function ownedStateIds(owner:ResourceId):Null<Array<ResourceId>> return ownedStates.get(owner);
  public function ownsResource(owner:ResourceId, child:ResourceId):Bool {
    var ids = ownedStates.get(owner);
    if (ids != null) for (index in 0...ids.length) if (ids[index] == child) return true;
    return false;
  }

  final disposers:Map<Int, Void -> Void>;
  final paths:Map<Int, String>;
  /** The IDs in `paths`, oldest first, so a prune can walk them in place instead of snapshotting the map's keys. */
  final pathIds:Array<Int> = [];
  final managed:IdSet;
  /** Stable membership avoids copying all managed IDs on each frame. */
  final managedIds:Array<ResourceId> = [for (_ in 0...256) new ResourceId(0)];
  var managedCount:Int = 0;
  /** Reuse the normal cleanup worklist; nested cleanup gets its own list. */
  final staleScratch:Array<ResourceId> = [];
  var sweeping:Bool = false;
  final frameUsed:IdSet;
  /** Scratch for usedIdsSince, reused so collecting a subtree's states allocates only the result. */
  final seenScratch:IdSet = new IdSet(256);
  final frameUseOrder:Array<ResourceId>;
  var frameUseCount:Int = 0;
  public var frameActive(default, null):Bool;

  public function new() {
    disposers = new Map();
    paths = new Map();
    managed = new IdSet(256);
    frameUsed = new IdSet();
    frameUseOrder = [for (_ in 0...256) new ResourceId(0)];
    frameActive = false;
  }

  @:allow(haxeon.ui.core.BuildContext) function handle<T>(id:WidgetId):State<T> {
    var result = handles.get(id.value);
    if (result == null) throw 'Widget state has not been initialized for ${describe(id)}';
    return cast result;
  }

  /** Resolve hash collisions without aliasing state belonging to another scoped path. */
  public function resolveWidgetId(path:String):WidgetId {
    var value = KeyScope.widgetIdForPath(path).value;
    while (paths.exists(value) && paths.get(value) != path) value = value == 0x7fffffff ? 1 : value + 1;
    var id = new WidgetId(value);
    rememberPath(id, path);
    return id;
  }

  /** Records the scoped key path used to make a widget ID for diagnostics. */
  public function rememberPath(id:WidgetId, path:String):Void {
    if (id != null && path != null) {
      var known = paths.get(id.value);
      if (known != path) {
        if (known == null) pathIds.push(id.value);
        paths.set(id.value, path);
      }
    }
  }

  /** Keep diagnostic paths only for mounted nodes or retained application state. */
  public function prunePaths(mounted:Map<Int, RenderNode>):Void {
    var retained = retainedWidgetIds(mounted);
    var read = 0, write = 0;
    while (read < pathIds.length) {
      var id = pathIds[read++];
      if (!paths.exists(id)) continue;
      if (!mounted.exists(id) && !handles.exists(id) && !retained.has(id)) paths.remove(id);
      else pathIds[write++] = id;
    }
    pathIds.resize(write);
  }

  public function initialize<T>(id:WidgetId, initial:T):Void {
    if (id == null) throw "State requires a widget ID";
    if (!handles.exists(id.value)) handles.set(id.value, new State<T>(this, id, initial));
    markUsed(id);
  }

  /** Reserve one native instance lifetime before its body captures descendant resource usage. */
  public function beginScope():ScopeResourceId {
    var id = new ScopeResourceId(nextScopeId);
    while (scopes.exists(id) || frameUsed.has(ResourceId.scope(id).rawValue())) {
      nextScopeId = nextScopeId == 0x7fffffff ? 1 : nextScopeId + 1;
      id = new ScopeResourceId(nextScopeId);
    }
    nextScopeId = nextScopeId == 0x7fffffff ? 1 : nextScopeId + 1;
    markUsedResource(ResourceId.scope(id));
    return id;
  }

  /** Borrowed membership for one key-cache prune, including hidden native bodies. */
  @:allow(haxeon.ui.core.WidgetIdCache) function retainedWidgetIds(mounted:Map<Int, RenderNode>):IdSet {
    retainedWidgetScratch.clear();
    for (index in 0...managedCount) {
      var id = managedIds[index];
      var owner = id.isScope() ? scopes.get(id.scopeId()) : null;
      if (owner == null || owner.disposed) continue;
      retainedWidgetScratch.add(owner.identityId);
      if (owner.root != null && mounted.get(owner.root.id.value) != owner.root) retainBodyWidgetIds(owner.root,
        mounted);
    }
    return retainedWidgetScratch;
  }

  function retainBodyWidgetIds(node:RenderNode, mounted:Map<Int, RenderNode>):Void {
    if (!mounted.exists(node.id.value)) retainedWidgetScratch.add(node.id.value);
    for (child in node.children) retainBodyWidgetIds(child, mounted);
  }

  public function scopeOwner(id:ScopeResourceId):Null<RenderScope> return scopes.get(id);

  /** Install one instance owner; cached instances with the same widget identity remain independent. */
  public function installScope(owner:RenderScope):Void {
    var id = owner.resourceId;
    var previous = scopes.get(id);
    if (previous != null && previous != owner) throw "Native scope resource already has an owner";
    scopes.set(id, owner);
    var resource = ResourceId.scope(id);
    if (!managed.has(resource.rawValue())) {
      managed.add(resource.rawValue());
      appendManaged(resource);
    }
  }

  /** Release a native record immediately, including independent updates outside a full-frame sweep. */
  public function releaseScope(owner:RenderScope):Void {
    var id = owner.resourceId, current = scopes.get(id);
    if (current != null && current != owner) return;
    scopes.remove(id);
    var resource = ResourceId.scope(id);
    ownedStates.remove(resource);
    managed.remove(resource.rawValue());
    if (!sweeping && managedCount > 256 && managedCount > managed.count() * 2) compactManaged();
  }

  function compactManaged():Void {
    var read = 0, write = 0;
    seenScratch.clear();
    while (read < managedCount) {
      var id = managedIds[read++];
      if (managed.has(id.rawValue()) && seenScratch.add(id.rawValue())) managedIds[write++] = id;
    }
    managedCount = write;
  }

  /** Starts liveness tracking for resource-backed widget state. */
  public function beginFrame():Void {
    frameUsed.clear();
    frameUseCount = 0;
    frameActive = true;
  }

  /** Returns a marker for state usage captured during the current frame. */
  public function usageMarker():Int return frameUseCount;

  /** Returns state IDs first touched after a usage marker. */
  public function usedIdsSince(marker:Int, ?previous:Array<ResourceId>):Array<ResourceId> {
    var start = marker < 0 ? 0 : marker > frameUseCount ? frameUseCount : marker;
    var count = 0, same = previous != null;
    seenScratch.clear();
    for (index in start...frameUseCount) {
      var id = frameUseOrder[index];
      if (!seenScratch.add(id.rawValue())) continue;
      if (previous == null || count >= previous.length || previous[count] != id) same = false;
      count++;
    }
    if (previous != null && same && previous.length == count) return previous;
    var result:Array<ResourceId> = [];
    result.resize(count);
    seenScratch.clear();
    var position = 0;
    for (index in start...frameUseCount) {
      var id = frameUseOrder[index];
      if (seenScratch.add(id.rawValue())) result[position++] = id;
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
  public function retain(ids:Array<ResourceId>, recordUsage:Bool = true):Void {
    if (ids == null) return;
    for (id in ids) if (id.isScope() ? scopes.exists(id.scopeId()) : handles.exists(id.payload())) {
      if (frameActive) frameUsed.add(id.rawValue());
      if (recordUsage && (frameActive || usageCaptures > 0)) appendUsage(id);
      var children = ownedStates.get(id);
      if (children != null) retain(children, false);
    }
  }

  /** Marks an initialized state as used by the current render tree. */
  public function touch(id:WidgetId):Void {
    if (id == null || !contains(id)) throw "Widget state has not been initialized";
    markUsed(id);
    var children = ownedStates.get(ResourceId.widget(id));
    if (children != null) retain(children, false);
  }

  public function touchScope(id:ScopeResourceId):Void {
    if (!scopes.exists(id)) throw "Native scope has not been initialized";
    var resource = ResourceId.scope(id);
    markUsedResource(resource);
    var children = ownedStates.get(resource);
    if (children != null) retain(children, false);
  }

  @:allow(haxeon.ui.core.State) function check(id:WidgetId):Void {
    if (id == null || !handles.exists(id.value)) throw 'Widget state has not been initialized for ${describe(id)}';
  }

  /** Releases resource-backed state that was absent from the completed tree. */
  public function endFrame():Void {
    if (!frameActive) return;
    var nested = sweeping;
    var stale:Array<ResourceId> = nested ? [] : staleScratch;
    stale.resize(0);
    sweeping = true;
    for (index in 0...managedCount) {
      var id = managedIds[index];
      if (!frameUsed.has(id.rawValue())) stale.push(id);
    }
    var failure:Dynamic = null;
    for (id in stale) {
      try {
        if (id.isScope()) {
          var owner = scopes.get(id.scopeId());
          if (owner != null) owner.dispose();
        } else {
          var disposer = disposers.get(id.payload());
          if (disposer != null) disposer();
        }
      } catch (error:Dynamic) {
        if (failure == null) failure = error;
      }
      managed.remove(id.rawValue());
      if (id.isScope()) scopes.remove(id.scopeId());
      else {
        disposers.remove(id.payload());
        handles.remove(id.payload());
      }
      ownedStates.remove(id);
    }
    if (stale.length > 0) compactManaged();
    stale.resize(0);
    sweeping = nested;
    frameUsed.clear();
    frameUseCount = 0;
    frameActive = false;
    if (failure != null) throw failure;
  }

  public function contains(id:WidgetId):Bool return id != null && handles.exists(id.value);

  /** Bounded-run diagnostics for detecting retained widget state growth. */
  public function diagnosticCounts(): {values: Int, paths: Int, resources: Int} {
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
    if (id == null) return "null";
    var path = paths.get(id.value);
    return path == null ? Std.string(id.value) : Std.string(id.value) + " (" + path + ")";
  }

  /** Registers one native-resource cleanup callback for persistent widget state. */
  public function onDispose(id:WidgetId, disposer:Void -> Void):Void {
    if (id == null || disposer == null || !handles.exists(id.value)
      || disposers.exists(id.value)) throw "State disposal requires initialized state and one callback per widget ID";
    disposers.set(id.value, disposer);
  }

  /** Registers a resource cleanup callback and enables per-frame liveness cleanup. */
  public function onUnmount(id:WidgetId, disposer:Void -> Void):Void {
    onDispose(id, disposer);
    var resource = ResourceId.widget(id);
    managed.add(resource.rawValue());
    appendManaged(resource);
  }

  /** Releases registered widget resources and clears the store. */
  public function dispose():Void {
    var nested = sweeping;
    sweeping = true;
    var failure:Dynamic = null;
    for (index in 0...managedCount) {
      var id = managedIds[index];
      var owner = id.isScope() ? scopes.get(id.scopeId()) : null;
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
        if (failure == null) failure = error;
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
    sweeping = nested;
    if (failure != null) throw failure;
  }

  function appendManaged(id:ResourceId):Void {
    if (!sweeping && managedCount == managedIds.length && managedCount > managed.count()) compactManaged();
    if (managedCount == managedIds.length) managedIds.resize(managedIds.length * 2);
    managedIds[managedCount++] = id;
  }

  /** Logical length is independent of capacity, including nested usage captures. */
  function appendUsage(id:ResourceId):Void {
    if (frameUseCount == frameUseOrder.length) frameUseOrder.resize(frameUseOrder.length * 2);
    frameUseOrder[frameUseCount++] = id;
  }

  function markUsed(id:WidgetId):Void markUsedResource(ResourceId.widget(id));

  function markUsedResource(id:ResourceId):Void {
    if (frameActive) frameUsed.add(id.rawValue());
    if (frameActive || usageCaptures > 0) appendUsage(id);
  }
}
