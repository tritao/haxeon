import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;

@:access(haxeon.ui.core.BuildContext) class RetainedWidgetIdMain {
  static var context:BuildContext;
  static var mounted:Map<Int, RenderNode>;
  static var childId:WidgetId;
  static var childPath:String;
  public static function prepare():Void {
    context = new BuildContext(new StateStore());
    context.beginFrame();
    var marker = context.stateUsageMarker();
    var root = new TrackedScope("cached", () -> new RetainedBody()).build(context);
    var ids = context.stateIdsUsedSince(marker);
    var owner = context.renderScopeAt(root);
    if (owner == null) throw "Fixture failed to mount its native scope";
    childId = root.children[0].id;
    childPath = owner.capturedScope.widgetPath("child");
    context.id("abandoned");
    var abandonedPath = context.scope.widgetPath("abandoned");
    context.stateStore.endFrame();
    context.beginFrame();
    context.retainStateIds(ids);
    context.stateStore.endFrame();
    mounted = new Map();
    context.pruneKeyCaches(mounted, 1);
    if (context.idsByPath.get(childPath) != childId) throw "Pruning dropped a child ID of a retained native body";
    if (context.idsByPath.get(abandonedPath) != null) throw "Pruning retained an abandoned ID";
  }
  public static function perform(frames:Int):Int {
    for (_ in 0...frames) {
      context.idsByPath.prune(mounted, context.stateStore);
      context.stateStore.prunePaths(mounted);
      if (context.idsByPath.get(childPath) != childId) return -1;
    }
    return frames;
  }
  static function main():Int {
    prepare();
    if (perform(8) != 8) return 1;
    #if !wasm
    var before = hl.Gc.totalAllocated();
    #end
    if (perform(1024) != 1024) return 2;
    #if !wasm
    if (hl.Gc.totalAllocated() != before) return 3;
    #end
    context.beginFrame();
    context.stateStore.endFrame();
    context.pruneKeyCaches(mounted, 2);
    if (context.idsByPath.get(childPath) != null) throw "Disposed native body kept its child ID cache";
    context.dispose();
    return 42;
  }
}
private class RetainedBody implements View {
  public function new() {
  }
  public function build(context:BuildContext):RenderNode {
    var root = context.createNode(context.rootId("body"));
    root.add(context.createNode(context.id("child")));
    return root;
  }
}
