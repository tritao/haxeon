import haxeon.reactive.Signal;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.component.BoundText;
import haxeon.ui.theme.Theme;
import haxeon.ui.core.UiDirtyFlag;
import haxeon.ui.debug.UiStyleInvalidationMetrics;
import haxeon.ui.LayoutVisualKind;

class BoundTextMain {
  static function main():Int {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<String>("one");
    var reads = 0;
    context.beginFrame();
    var scheduled = 0;
    context.onBindingFrameRequested = () -> scheduled++;
    var binding = new BoundText("status", () -> {reads++;
    return source.value;
    });
    var node = context.trackReads(() -> binding.build(context));
    store.endFrame();
    var contentRevision = node.contentRevision;
    var geometryRevision = node.geometryRevision;
    if (node.layout.text != "one" || !source.hasFieldReaders(0) || reads != 1) return 1;
    source.value = "two";
    if (scheduled != 1) return 7;
    context.requestBindingFrame();
    if (scheduled != 1) return 10;
    context.flushTextBindings(node);
    context.consumeBindingFrameRequest();
    if (node.layout.text != "two" || node.semantics == null || node.semantics.label != "two" || reads != 2) return 2;
    var changes = UiStyleInvalidationMetrics.compare(node, node);
    if (!changes.invalidationFlags.contains(UiDirtyFlag.NeedsTextLayout)
      || !changes.invalidationFlags.contains(UiDirtyFlag.NeedsLayout)
      || !changes.invalidationFlags.contains(UiDirtyFlag.NeedsPaint)
      || !changes.invalidationFlags.contains(UiDirtyFlag.NeedsSemantics)
      || node.contentRevision != contentRevision + 1 || node.geometryRevision != geometryRevision + 1) return 3;
    source.value = "two";
    if (scheduled != 1) return 8;
    context.flushTextBindings(node);
    if (node.layout.text != "two" || reads != 2) return 4;
    context.beginFrame();
    store.endFrame();
    if (source.hasFieldReaders(0)) return 5;
    source.value = "three";
    if (scheduled != 1) return 9;
    context.flushTextBindings(node);
    if (node.layout.text != "two") return 6;
    context.dispose();
    return hiddenBinding() ? 42 : 11;
  }

  static function hiddenBinding():Bool {
    var context = new BuildContext(new StateStore());
    var source = new Signal<String>("one"), reads = 0;
    context.beginFrame();
    var root = context.createNode(context.id("holder"), LayoutVisualKind.Box);
    var node = new BoundText("hidden", () -> {reads++;
    return source.value;
    }).build(context);
    root.add(node);
    context.stateStore.endFrame();
    source.value = "two";
    node.detach();
    context.flushTextBindings(root);
    var hidden = reads == 1 && node.layout.text == "one" && source.hasFieldReaders(0);
    source.value = "three";
    root.add(node);
    context.flushTextBindings(root);
    var restored = reads == 2 && node.layout.text == "three";
    context.stateStore.dispose();
    context.dispose();
    if (!hidden) throw "Hidden binding read early: reads=" + reads + " text=" + node.layout.text;
    if (!restored) throw "Remounted binding stayed stale: reads=" + reads + " text=" + node.layout.text;
    if (source.hasFieldReaders(0)) throw "Disposed binding kept its subscription";
    return true;
  }
}
