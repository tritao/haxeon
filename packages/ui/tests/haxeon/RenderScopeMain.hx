import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.component.ScopeView;
import haxeon.ui.theme.Theme;
import haxeon.reactive.Signal;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.WidgetId;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutSizing;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Insets;

/** Native structural ownership does not reconcile or redirect removed nodes. */
class RenderScopeMain {
  static function node(id:Int):RenderNode return new RenderNode(new WidgetId(id));
  static function publish(context:BuildContext, root:RenderNode):Void {
    var instances = new Map<Int, RenderNode>();
    root.walk(node -> instances.set(node.id.value, node));
    context.beginLayoutSubmission(instances);
  }
  static function main():Int {
    var primary = new Signal<Bool>(true), first = new Signal<Int>(1), second = new Signal<Int>(2);
    var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
    context.beginFrame();
    var decoration = node(2), runs = 0;
    var component = new NativeScopeFixture("primary", build -> {var value = primary.value ? first.value : second.value;
    runs++;
    var result = build.createNode(build.rootId("body"));
    result.layout.text = Std.string(value + 10);
    return result;
    });
    var root = component.build(context), scope = context.renderScopeAt(root);
    if (scope == null) return 15;
    root.add(decoration);
    var old = root;
    scope.refresh();
    if (runs != 1
      || context.patchedPriors().get(root.id.value) != null || context.bindingRequestRevision != 0) return 1;
    publish(context, root);
    first.value = 3;
    if (context.bindingRequestRevision != 1) return 2;
    scope.refresh();
    root = context.currentRoot(root);
    if (runs != 2 || context.patchedPriors().get(root.id.value) != old
      || context.bindingRequestRevision != 1 || root.children.length != 1 || root.children[0] != decoration
      || old.parent != null || old.replacedBy != null || root.layout.text != "13" || !root.id.equals(old.id)) return 3;
    context.consumeBindingFrameRequest();
    primary.value = false;
    scope.refresh();
    if (first.hasFieldReaders(0) || !second.hasFieldReaders(0) || runs != 3) return 4;
    var before = context.bindingRequestRevision;
    first.value = 4;
    scope.refresh();
    if (context.bindingRequestRevision != before || runs != 3) return 5;
    scope.dispose();
    scope.dispose();
    if (primary.hasFieldReaders(0) || second.hasFieldReaders(0)) return 6;
    second.value = 5;
    scope.refresh();
    if (context.bindingRequestRevision != before || runs != 3) return 7;
    var recoverySource = new Signal<Int>(0);
    var recoveryRoot:RenderNode = null;
    var recoveryComponent = new NativeScopeFixture("recovering", build -> {var value = recoverySource.value;
    if (value == 1) {
      // A retained child can be detached while constructing the next body, before a later child fails.
      recoveryRoot.detach();
      throw "Expected scope failure";
    }
    var result = build.createNode(build.rootId("body"));
    result.layout.text = Std.string(41 + value);
    return result;
    });
    recoveryRoot = recoveryComponent.build(context);
    var recovering = context.renderScopeAt(recoveryRoot);
    if (recovering == null) return 16;
    context.consumeBindingFrameRequest();
    var holder = node(40);
    holder.add(recoveryRoot);
    var installed = recoveryRoot;
    recoverySource.value = 1;
    var failed = false;
    try recovering.refresh() catch (_:Dynamic) failed = true;
    if (!failed
      || holder.children.length != 1 || holder.children[0] != installed || installed.parent != holder) return 8;
    var failedRequests = context.bindingRequestRevision;
    context.consumeBindingFrameRequest();
    recoverySource.value = 2;
    if (context.bindingRequestRevision <= failedRequests) return 9;
    recovering.refresh();
    recoveryRoot = context.currentRoot(recoveryRoot);
    if (recoveryRoot.layout.text != "43" || installed.parent != null || holder.children[0] != recoveryRoot) return 10;
    recovering.dispose();
    if (recoverySource.hasFieldReaders(0)) return 11;
    context.endPatchFrame();
    var width = new Signal<Float>(80);
    var elementComponent = new NativeScopeFixture("element", build -> {var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(width.value);
    style.height = LayoutAxis.fixed(24);
    style.padding = new Insets(4, 4, 4, 4);
    style.positioning = LayoutPositioning.Absolute;
    style.positionX = 7;
    style.zIndex = 2;
    return build.createNode(build.rootId("body"), LayoutVisualKind.Box, style);
    });
    var elementRoot = elementComponent.build(context), elementScope = context.renderScopeAt(elementRoot);
    if (elementScope == null) return 17;
    var element = elementRoot;
    if (elementRoot.layout.style.width.value != 80 || elementRoot.layout.style.height.value != 24
      || elementRoot.layout.style.positioning != LayoutPositioning.Absolute
      || elementRoot.layout.style.positionX != 7 || !elementRoot.hitTestSelf
      || elementRoot.children.length != 0 || element.layout.style.padding.left != 4) return 12;
    elementRoot.layout.style.zIndex = 9;
    publish(context, elementRoot);
    width.value = 100;
    elementScope.refresh();
    var previousElement = elementRoot;
    elementRoot = context.currentRoot(elementRoot);
    var prior = context.patchedPriors().get(elementRoot.id.value);
    if (prior == null || prior != previousElement || prior == elementRoot || prior.layout.style.width.value != 80
      || elementRoot.layout.style.width.value != 100 || elementRoot.layout.style.zIndex != 9) return 13;
    context.endPatchFrame();
    elementScope.refresh();
    if (context.patchedPriors().get(elementRoot.id.value) != null) return 14;
    elementScope.dispose();
    // Independent refreshes reuse mounted IDs; two fresh mounts in one build must still reject a duplicate key.
    context.beginFrame();
    var duplicate = new NativeScopeFixture("duplicate", build -> {var value = first.value;
    return build.createNode(build.rootId("body"));
    });
    var installedRoot = duplicate.build(context), installedOwner = context.renderScopeAt(installedRoot);
    var rejected = false;
    try duplicate.build(context) catch (error:Dynamic) rejected = Std.string(error).indexOf("Duplicate widget ID") >= 0;
    if (!rejected || installedOwner == null || installedOwner.disposed
      || context.renderScopeAt(installedRoot) != installedOwner || !first.hasFieldReaders(0)) return 18;
    context.dispose();
    return 42;
  }
}

/** A test component supplies changing bodies; the native mount path supplies no callback adapters. */
private class NativeScopeFixture implements ScopeView {
  final key:String;
  final make:BuildContext -> RenderNode;
  public function new(key:String, make:BuildContext -> RenderNode) {
    this.key = key;
    this.make = make;
  }
  public function scopeKey():String return key;
  public function inputsEqual(previous:ScopeView):Bool return previous == this;
  public function buildBody(context:BuildContext):RenderNode return make(context);
  public function build(context:BuildContext):RenderNode return context.mountComponent(this);
}
