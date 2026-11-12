import haxeon.reactive.Signal;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.RetainedVariants;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.text.Text;

class ScopeVariantRootMain {
  static function main():Int {
    var choice = new Signal<Bool>(true);
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    context.beginFrame();
    var view = new TrackedScope("variants", () -> {
      var label = choice.value ? "A" : "B";
      return new RetainedVariants("leaves", label, _ -> new Text(label));
    });
    var first = view.build(context);
    var owner = context.renderScopeAt(first);
    if (first.layout.text != "A") throw "Initial variant is not A";
    choice.value = false; owner.refresh();
    var second = context.currentRoot(first);
    if (second.layout.text != "B") throw "Second variant is not B";
    choice.value = true; owner.refresh();
    var again = context.currentRoot(second);
    if (again.layout.text != "A") throw "Returning to A returned B";
    if (again != first) throw "Returning to A rebuilt its cached leaf";
    context.dispose();context.stateStore.dispose();
    nestedVariants();
    return 42;
  }
  static function nestedVariants():Void {
    var choice = new Signal<Bool>(true);
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    context.beginFrame();
    var view = new TrackedScope("outer", () -> {
      var label = choice.value ? "A" : "B";
      return new RetainedVariants("nested", label, _ -> new TrackedScope("inner", () -> new Text(label)));
    });
    var first = view.build(context);
    var outer = context.renderScopeAt(first);
    // The shared physical root carries the inner owner; the native scheduler refreshes its outer reader.
    choice.value = false;context.flushRenderScopes();
    var second = context.currentRoot(first);
    if (second.layout.text != "B") throw "Nested variant did not select B";
    choice.value = true;context.flushRenderScopes();
    var again = context.currentRoot(second);
    if (again.layout.text != "A") throw "Cached nested variant A resolved to enclosing variant B";
    context.dispose();context.stateStore.dispose();
  }

}
