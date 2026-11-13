import haxeon.reactive.Signal;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.Button;

/** A parent rebuild replaces the current scope body and retires its pending old computation. */
class ScopeLegacyReplacementMain implements View {
  final generation = new Signal<Int>(0);
  final text = new Signal<String>("A");
  var nativeBuilds = 0;

  public function new() {
  }

  public function build(context:BuildContext):RenderNode {
    var id = context.id("legacy");
    return context.selfUpdating(id, () -> {var current = generation.value;
    var root = new RenderNode(id, LayoutVisualKind.Box, new LayoutStyle());
    root.add(new TrackedScope("scope", () -> {nativeBuilds++;
    return new Button(text.value, null, null, "button");
    }).build(context));
    return root;
    });
  }

  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var view = new ScopeLegacyReplacementMain();
    context.beginFrame();
    var root = context.trackReads(() -> view.build(context));
    store.endFrame();
    var first = root.children[0];
    view.text.value = "B";
    context.flushRenderScopes(root);
    var second = root.children[0];
    if (first == second || !first.id.equals(second.id)) throw "Independent body replacement lost identity";
    var before = view.nativeBuilds;
    view.generation.value = 1;
    view.text.value = "A";
    context.flushRenderScopes(root);
    if (view.nativeBuilds != before) throw "Native child ran before its pending parent";
    context.applyPatches(root);
    context.flushRenderScopes(root);
    if (root.children.length != 1 || root.layout.children.length != 1 || root.children[0] == second
      || second.parent != null) throw "Parent replacement retained a stale authored child";
    if (view.nativeBuilds != before + 1) throw "Removed native body ran after parent replacement";
    if (context.hasPendingRenderScopes()) throw "Removed native body remained pending";
    context.dispose();
    return 42;
  }
}
