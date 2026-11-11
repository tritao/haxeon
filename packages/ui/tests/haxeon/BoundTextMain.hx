import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.component.BoundText;
import haxeon.ui.theme.Theme;

class BoundTextMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<String>("one");
    var reads = 0;
    context.beginFrame();
    var scheduled = 0;
    context.onBindingFrameRequested = () -> scheduled++;
    var binding = new BoundText("status", () -> { reads++; return source.value; });
    var node = context.trackReads(() -> binding.build(context));
    store.endFrame();
    if (node.layout.text != "one" || !source.hasFieldReaders(0) || reads != 1) return 1;
    source.value = "two";
    if (scheduled != 1) return 7;
    context.requestBindingFrame();
    if (scheduled != 1) return 10;
    ReactiveRuntime.flushEffects();
    context.consumeBindingFrameRequest();
    if (node.layout.text != "two" || node.semantics == null || node.semantics.label != "two" || reads != 2) return 2;
    if (!context.editAnnounced(node)) return 3;
    source.value = "two";
    if (scheduled != 1) return 8;
    ReactiveRuntime.flushEffects();
    if (node.layout.text != "two" || reads != 2) return 4;
    context.beginFrame();
    store.endFrame();
    if (source.hasFieldReaders(0)) return 5;
    source.value = "three";
    if (scheduled != 1) return 9;
    ReactiveRuntime.flushEffects();
    if (node.layout.text != "two") return 6;
    context.dispose();
    return 42;
  }
}
