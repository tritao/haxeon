import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.KeyScope;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;

class KeyScopeTests {
  static function check(value:Bool, message:String):Void if (!value) throw message;
  public static function main():Int {
    var root = new KeyScope();
    var a = root.child(new Key("a")), b = root.child(new Key("b"));
    var deep = a.child(new Key("deep"));
    var rootPath = root.widgetPath("root"), kept = a.widgetPath("keep"), nested = deep.widgetPath("keep");
    a.widgetPath("stale"); b.widgetPath("stale");
    var original = a.widgetId("keep").value;
    check(root.cachedEntries() == 8, "all scopes and widget paths counted");
    check(root.prune(function(path) return path == rootPath || path == kept || path == nested), "live descendants retained");
    check(root.cachedEntries() == 5, "only removed scopes and paths discarded");
    check(root.child(new Key("a")) == a && a.child(new Key("deep")) == deep, "retained scopes keep identity");
    check(a.widgetId("keep").value == original, "retained widget ID stable");
    check(!root.prune(function(_) return false) && root.cachedEntries() == 0, "empty tree fully pruned");
    var remounted = root.child(new Key("a"));
    check(remounted != a && remounted.widgetId("keep").value == original, "remount recreates deterministic ID");
    for (cycle in 0...20) {
      for (i in 0...8) root.child(new Key("branch" + i)).widgetPath("item");
      var branchPath = root.child(new Key("branch3")).widgetPath("item");
      root.prune(function(path) return path == kept || path == branchPath);
      check(root.cachedEntries() == 4, "compaction removes neighbouring stale branches without losing live branches");
    }
    // The build context walks its key caches only when something could have gone stale.
    var context = new BuildContext(new StateStore());
    var mounted = new Map<Int, RenderNode>();
    context.id("first");
    context.id("second");
    check(context.diagnosticKeyCounts().ids == 2 && context.keyCachePrunes == 0, "ids are cached before any pruning");
    context.pruneKeyCaches(mounted, 7);
    check(context.diagnosticKeyCounts().ids == 0 && context.keyCachePrunes == 1, "ids of unmounted widgets are pruned");
    context.pruneKeyCaches(mounted, 7);
    context.pruneKeyCaches(mounted, 7);
    check(context.keyCachePrunes == 1, "pruning is skipped while the mounted nodes and the cache sizes are unchanged");
    context.id("third");
    context.pruneKeyCaches(mounted, 7);
    check(context.keyCachePrunes == 2 && context.diagnosticKeyCounts().ids == 0, "a newly cached id is pruned though the mounted nodes did not change");
    context.pruneKeyCaches(mounted, 8);
    check(context.keyCachePrunes == 3, "a change in the mounted nodes makes pruning walk the caches again");
    // Scopes that hold no widget only cache path strings: a few are left, a crowd of them is pruned.
    for (i in 0...10) context.withScope(new Key("few" + i), function() return 0);
    context.pruneKeyCaches(mounted, 8);
    check(context.keyCachePrunes == 3 && context.diagnosticKeyCounts().paths == 10, "a few empty scopes are left for later");
    for (i in 0...300) context.withScope(new Key("many" + i), function() return 0);
    context.pruneKeyCaches(mounted, 8);
    check(context.keyCachePrunes == 4 && context.diagnosticKeyCounts().paths == 0, "empty scopes are pruned once enough have collected");
    Sys.println("Key scope tests passed");
    return 0;
  }
}
