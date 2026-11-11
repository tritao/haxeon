import Equatable;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.component.EqualChild;
import haxeon.ui.theme.Theme;

struct Props implements Equatable {
  public var value:Int;
  public function new(value:Int) this.value = value;
}

class Leaf implements View {
  final source:Signal<Int>;
  public static var builds = 0;
  public function new(source:Signal<Int>) this.source = source;
  public function build(context:BuildContext):RenderNode {
    builds++;
    var value = source.value;
    return new RenderNode(context.id("leaf"), LayoutVisualKind.Box);
  }
}

class EqualChildMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(0);
    function build(value:Int):RenderNode {
      context.beginFrame();
      context.resetObserved();
      var view = new EqualChild<Props>("child", new Props(value), (_, _) -> new Leaf(source));
      var root = context.trackReads(() -> view.build(context));
      store.endFrame();
      return root;
    }
    var first = build(1);
    if (Leaf.builds != 1 || !source.hasFieldReaders(0)) return 1;
    var same = build(1);
    if (Leaf.builds != 1 || same != first) return 2;
    build(2);
    if (Leaf.builds != 2) return 3;
    source.value = 1;
    build(2);
    if (Leaf.builds != 3) return 4;
    context.beginFrame();
    store.endFrame();
    if (source.hasFieldReaders(0)) return 5;
    context.dispose();
    return 42;
  }
}
