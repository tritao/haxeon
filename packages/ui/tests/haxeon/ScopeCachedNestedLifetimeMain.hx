import haxeon.reactive.Signal;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.RetainedVariants;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.text.Text;

class ScopeCachedNestedLifetimeMain {
  static function main():Int {
    var choice = new Signal<Bool>(true), value = new Signal<Int>(1);
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    context.beginFrame();
    var view = new TrackedScope("outer", () -> {var label = choice.value ? "A" : "B";
    return new RetainedVariants("nested", label, _ -> new TrackedScope("inner", () -> new Text(label + value.value)));
    });
    var first = view.build(context), owner = context.renderScopeAt(first);
    if (owner == null) throw "Nested scope has no owner";
    choice.value = false;
    context.flushRenderScopes(first);
    var second = context.currentRoot(first);
    if (second.layout.text != "B1") throw "Did not switch to nested B";
    if (owner.disposed) throw "Inactive cached nested component was disposed";
    value.value = 2;
    context.flushRenderScopes(first);
    choice.value = true;
    context.flushRenderScopes(first);
    var returned = context.currentRoot(first);
    if (returned.layout.text != "A2") throw "Returning nested A lost its independent live updates";
    context.dispose();
    context.stateStore.dispose();
    if (value.hasFieldReaders(0)) throw "Released cached component retained a reader";
    return 42;
  }
}
