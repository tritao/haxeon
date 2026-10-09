import haxeon.ui.core.Key;
import haxeon.ui.core.KeyScope;

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
    Sys.println("Key scope tests passed");
    return 0;
  }
}
