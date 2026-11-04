import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.BuildContext.SelfUpdatingBuild;
import haxeon.ui.core.BuildContext.UpdatingDependencies;
import haxeon.ui.core.Dependencies;
import haxeon.ui.core.InteractionStateSnapshot;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;
import haxeon.ui.theme.Theme;

@:access(haxeon.ui.core.BuildContext)
@:access(haxeon.ui.core.BuildContext.SelfUpdatingBuild)
class ReactivePruneSmoke {
 static function install(context:BuildContext, source:Signal<Int>, id:Int):SelfUpdatingBuild {
  var capture = new Dependencies(true);
  ReactiveRuntime.withTracking(capture, function() return source.value);
  var observed = new Dependencies(); observed.replaceSlice(capture, 0);
  var dependencies = new UpdatingDependencies(); dependencies.observed = observed;
  var widgetId = new WidgetId(id);
  var entry = new SelfUpdatingBuild(widgetId, function() return null, null, null, []);
  entry.root = new RenderNode(widgetId, LayoutVisualKind.Box, null);
  entry.dependencies = dependencies;
  observed.setInvalidationOwner(context, entry);
  context.registerSelfUpdatingBuild(id, entry);
  return entry;
 }
 public static function run():Int {
  var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
  var mounted:Map<Int,RenderNode> = new Map();
  var abandoned = new Signal<Int>(0), dead = install(context, abandoned, 1);
  if (!abandoned.hasFieldReaders(0)) return 1;
  context.pruneSelfUpdatingBuilds(mounted);
  if (abandoned.hasFieldReaders(0) || dead.root != null) return 2;

  var cached = new Signal<Int>(0), entry = install(context, cached, 2);
  var root:RenderNode = cast entry.root;
  var first = new InteractionStateSnapshot(root, context);
  var second = new InteractionStateSnapshot(root, context);
  context.pruneSelfUpdatingBuilds(mounted);
  if (!cached.hasFieldReaders(0) || entry.root == null) return 3;
  first.dispose();
  if (!cached.hasFieldReaders(0)) return 4;
  if (!context.rearm(root.id, entry)) return 5;
  context.pruneSelfUpdatingBuilds(mounted);
  if (!cached.hasFieldReaders(0)) return 6;
  second.dispose();
  if (cached.hasFieldReaders(0) || entry.root != null) return 7;
  second.dispose();

  var shared = new Signal<Int>(0), old = install(context, shared, 3);
  var next = new SelfUpdatingBuild(new WidgetId(3), function() return null, null, null, []);
  var oldDependencies:UpdatingDependencies = cast old.dependencies;
  var sharedObserved:Dependencies = cast oldDependencies.observed;
  next.dependencies = oldDependencies;
  sharedObserved.setInvalidationOwner(context, next);
  context.registerSelfUpdatingBuild(3, next);
  if (!shared.hasFieldReaders(0)) return 8;
  context.pruneSelfUpdatingBuilds(mounted);
  if (shared.hasFieldReaders(0)) return 9;

  var transferred = new Signal<Int>(0), cachedEntry = install(context, transferred, 5);
  var cachedRoot:RenderNode = cast cachedEntry.root;
  var cachedSnapshot = new InteractionStateSnapshot(cachedRoot, context);
  var replacement = new SelfUpdatingBuild(new WidgetId(5), function() return null, null, null, []);
  var transferredDependencies:UpdatingDependencies = cast cachedEntry.dependencies;
  var transferredObserved:Dependencies = cast transferredDependencies.observed;
  replacement.root = new RenderNode(new WidgetId(5), LayoutVisualKind.Box, null);
  replacement.dependencies = transferredDependencies;
  transferredObserved.setInvalidationOwner(context, replacement);
  context.registerSelfUpdatingBuild(5, replacement);
  if (!context.rearm(cachedRoot.id, cachedEntry) || !transferred.hasFieldReaders(0)) return 12;
  transferred.value = 1;
  if (!cachedEntry.pending) return 13;
  cachedSnapshot.dispose(); context.pruneSelfUpdatingBuilds(mounted);
  if (transferred.hasFieldReaders(0)) return 14;

  var saturated = new SelfUpdatingBuild(new WidgetId(7), function() return null, null, null, []);
  saturated.ownership = 0x7fffffe8;
  var rejected = false;
  try saturated.retainSnapshot() catch (_:Dynamic) rejected = true;
  if (!rejected || saturated.ownership != 0x7fffffe8) return 16;

  var stable = new Signal<Int>(0), stableId = new WidgetId(4);
  var stableRoot = context.selfUpdating(stableId, function() {
   var value = stable.value;
   return new RenderNode(stableId, LayoutVisualKind.Box, null);
  });
  var failed = false;
  try context.selfUpdating(stableId, function() { if (stable.value == 0) throw "build failure"; return stableRoot; })
  catch (_:Dynamic) failed = true;
  if (!failed || context.updatingBuild(stableRoot) == null || !stable.hasFieldReaders(0)) return 10;
  failed = false;
  try context.selfUpdating(stableId, function() {
   var value = stable.value;
   return new RenderNode(new WidgetId(6), LayoutVisualKind.Box, null);
  }) catch (_:Dynamic) failed = true;
  if (!failed || context.updatingBuild(stableRoot) == null || !stable.hasFieldReaders(0)) return 15;
  context.pruneSelfUpdatingBuilds(mounted);
  if (stable.hasFieldReaders(0)) return 11;
  context.dispose();
  return 42;
 }
}
