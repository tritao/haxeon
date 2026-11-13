import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;

/** Claiming an existing tree needs no temporary visitor or per-node storage. */
@:access(haxeon.ui.core.BuildContext) class RetainedClaimMain {
  static var context:BuildContext;
  static var root:RenderNode;

  public static function prepare():Void {
    if (context != null) context.dispose();
    context = new BuildContext(new StateStore());
    root = new RenderNode(new WidgetId(1));
    for (index in 2...18) root.add(new RenderNode(new WidgetId(index)));
  }

  public static function perform(count:Int):Int {
    for (_ in 0...count) {
      context.claimed.clear();
      context.claimRetainedTree(root);
    }
    return context.claimed.count() == 17 ? count : -1;
  }

  static function main():Int {
    prepare();
    if (perform(8) != 8) return 1;
    var rejected = false;
    try context.claimRetainedTree(root) catch (error:Dynamic) {
      if (Std.string(error) != "Duplicate retained widget ID 1") throw error;
      rejected = true;
    }
    if (!rejected) throw "Duplicate retained IDs were accepted";
    #if !wasm
    var before = hl.Gc.totalAllocated();
    var claimed = perform(1024);
    var bytes = hl.Gc.totalAllocated() - before;
    if (claimed != 1024 || bytes != 0) throw "Retained tree claiming allocated: " + bytes;
    #end
    return 42;
  }
}
