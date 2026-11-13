import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.Key;
import haxeon.ui.core.KeyScope;

class KeyValueMain {
  static var context:BuildContext;
  static var body:Void -> Int;
  static function answer():Int return 42;
  public static function prepare():Void {
    if (context != null) context.dispose();
    context = new BuildContext(new StateStore());
    body = answer;
    context.withScope(new Key("known"), body);
  }
  public static function perform(count:Int):Int {
    var done = 0;
    for (_ in 0...count) if (context.withScope(new Key("known"), body) == 42) done++;
    return done;
  }
  static function main():Int {
    var root = new KeyScope();
    if (root.child(new Key("same")) != root.child(new Key("same"))) return 1;
    var left = root.child(new Key("ab")).child(new Key("c")).widgetId("leaf");
    var right = root.child(new Key("a")).child(new Key("bc")).widgetId("leaf");
    if (left.equals(right)) throw "Key path boundaries collided";
    var unicode = "a:b|λ/😀";
    if (new Key(unicode).rawValue() != unicode) throw "Key contents changed";
    for (invalid in [null, ""]) {
      var rejected = false;
      try new Key(invalid) catch (error:Dynamic) {
        if (Std.string(error) != "Widget keys must not be empty") throw error;
        rejected = true;
      }
      if (!rejected) throw "Invalid key accepted";
    }
    prepare();
    perform(8);
    #if !wasm
    var before = hl.Gc.totalAllocated();
    var done = perform(1024);
    var allocated = hl.Gc.totalAllocated() - before;
    if (done != 1024 || allocated != 0) throw "Scoped keys allocated: " + allocated;
    #end
    return 42;
  }
}
