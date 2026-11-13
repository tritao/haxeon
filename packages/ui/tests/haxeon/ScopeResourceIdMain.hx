import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.ResourceId;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;

/** Equal payloads in different resource domains must retain and dispose independently. */
@:access(haxeon.ui.core.StateStore) class ScopeResourceIdMain {
  static var released = 0;
  static function release():Void released++;

  static function main():Int {
    var store = new StateStore(), context = new BuildContext(store);
    var widget = new WidgetId(1);
    context.beginFrame();
    store.initialize(widget, 17);
    store.onUnmount(widget, release);
    var root = new TrackedScope("owner", () -> new ResourceBody()).build(context);
    var owner = context.renderScopeAt(root);
    if (owner == null || owner.resourceId.rawValue() != widget.value) return 1;
    var resource = ResourceId.scope(owner.resourceId), state = ResourceId.widget(widget);
    if (!resource.isScope() || state.isScope() || resource == state) return 2;
    store.setOwnedStates(resource, [state]);
    store.endFrame();
    store.beginFrame();
    store.touchScope(owner.resourceId);
    store.endFrame();
    if (owner.disposed || !store.contains(widget) || released != 0) return 3;
    store.beginFrame();
    store.touch(widget);
    store.endFrame();
    if (!owner.disposed || !store.contains(widget) || released != 0) return 4;
    store.beginFrame();
    store.endFrame();
    if (store.contains(widget) || released != 1) return 5;
    context.dispose();
    store.dispose();
    boundaryPayloads();
    return 42;
  }

  static function boundaryPayloads():Void {
    var store = new StateStore();
    store.beginFrame();
    store.nextScopeId = 0x40000000;
    var high = store.beginScope();
    store.nextScopeId = 0x7fffffff;
    var last = store.beginScope();
    var first = store.beginScope();
    if (high.rawValue() != 0x40000000 || last.rawValue() != 0x7fffffff
      || first.rawValue() != 1) throw "Scope resource counter lost its payload or wrap";
    for (id in [high, last]) {
      var scope = ResourceId.scope(id), widget = ResourceId.widget(new WidgetId(id.rawValue()));
      if (!scope.isScope() || widget.isScope() || scope == widget) throw "Resource domains depend on the encoded sign";
    }
    store.endFrame();
    store.dispose();
  }
}

private class ResourceBody implements View {
  public function new() {
  }
  public function build(context:BuildContext):RenderNode return context.createNode(context.rootId("body"));
}
