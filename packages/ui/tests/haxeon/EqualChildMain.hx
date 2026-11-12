import Equatable;
import haxeon.reactive.Signal;
import haxeon.reactive.ReactiveRuntime;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.component.EqualChild;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.component.BoundText;
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

class ReparentContainer implements View {
  final child:View;
  public function new(child:View) this.child = child;
  public function build(context:BuildContext):RenderNode {
    var root = new RenderNode(context.id("container"), LayoutVisualKind.Box);
    root.add(child.build(context));
    return root;
  }
}

class EmptyReparentBody implements View {
  public function new() {}
  public function build(context:BuildContext):RenderNode
    return new RenderNode(context.id("empty"), LayoutVisualKind.Box);
}

class LegacyScopeHost implements View {
  final child:View;
  public function new(child:View) this.child = child;
  public function build(context:BuildContext):RenderNode {
    var id = context.id("legacy-host");
    return context.selfUpdating(id, () -> {
      var root = new RenderNode(id, LayoutVisualKind.Box);
      root.add(child.build(context));
      return root;
    });
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
    if (!nativeReparent()) return 6;
    if (!nativeChildReads()) return 7;
    if (!retainedBindingLifetime()) return 8;
    return 42;
  }

  static function retainedBindingLifetime():Bool {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var revision = new Signal<Int>(0), value = new Signal<Int>(0);
    var view = new TrackedScope("retained-binding", () -> {
      var current = revision.value;
      return new EqualChild<Props>("stable", new Props(1),
        (_, _) -> new BoundText("text", () -> Std.string(value.value)));
    });
    context.beginFrame();
    var root = context.trackReads(() -> view.build(context));
    store.endFrame();
    revision.value = 1;
    context.beginFrame();
    context.flushRenderScopes();
    var mounted:Map<Int, RenderNode> = new Map();
    root.walk(node -> mounted.set(node.id.value, node));
    context.retainRenderScopeState(mounted);
    store.endFrame();
    // The cache hit must retain the leaf's effect beyond the frame that touched it.
    context.beginFrame();
    context.retainRenderScopeState(mounted);
    store.endFrame();
    value.value = 1;
    ReactiveRuntime.flushEffects();
    var valid = value.hasFieldReaders(0) && root.children[0].layout.text == "1";
    context.dispose();
    return valid;
  }

  static function nativeChildReads():Bool {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(0), revision = new Signal<Int>(0);
    var view = new TrackedScope("read-boundary", () -> {
      var value = revision.value;
      return new EqualChild<Props>("leaf", new Props(1), (_, _) -> new Leaf(source));
    });
    context.beginFrame();
    var host = context.trackReads(() -> new LegacyScopeHost(view).build(context));
    context.captureRootDependencies();
    store.endFrame();
    var count = Leaf.builds;
    revision.value = 1;
    context.flushRenderScopes();
    if (Leaf.builds != count || context.rootDependenciesDirty()) return false;
    source.value = 1;
    context.flushRenderScopes();
    var valid = Leaf.builds == count + 1 && !context.rootDependenciesDirty() && !context.hasPendingPatches;
    // An ancestor already queued to rebuild must supersede its pending native child body.
    source.value = 2;
    context.requestPatch(host.id);
    context.flushRenderScopes();
    valid = valid && Leaf.builds == count + 1;
    context.applyPatches();
    context.flushRenderScopes();
    valid = valid && Leaf.builds == count + 2 && !context.hasPendingRenderScopes();
    context.dispose();
    return valid;
  }

  static function nativeReparent():Bool {
    var store = new StateStore();
    var context = new BuildContext(store, null, null, null, Theme.light());
    var source = new Signal<Int>(0);
    var outerRevision = new Signal<Int>(0);
    var view = new TrackedScope("outer", () -> {
      var revision = outerRevision.value;
      if (revision >= 2) return new EmptyReparentBody();
      return new EqualChild<Props>("stable", new Props(1),
        (_, _) -> new ReparentContainer(new TrackedScope("inner", () -> new Leaf(source))));
    });
    function mount():RenderNode {
      context.beginFrame();
      context.resetObserved();
      var root = context.trackReads(() -> view.build(context));
      var mounted:Map<Int, RenderNode> = new Map();
      root.walk(node -> mounted.set(node.id.value, node));
      context.retainRenderScopeState(mounted);
      store.endFrame();
      context.pruneRenderScopes(mounted);
      return root;
    }
    var first = mount();
    var count = Leaf.builds;
    var second = mount();
    if (Leaf.builds != count || first.children.length != 0 || second.children.length != 1) return false;
    outerRevision.value = 1;
    context.flushRenderScopes();
    if (Leaf.builds != count || second.children.length != 1) return false;
    source.value = 1;
    context.flushRenderScopes();
    var valid = Leaf.builds == count + 1 && source.hasFieldReaders(0);
    outerRevision.value = 2;
    source.value = 2;
    context.flushRenderScopes();
    valid = valid && Leaf.builds == count + 1 && !source.hasFieldReaders(0);
    context.dispose();
    return valid;
  }
}
