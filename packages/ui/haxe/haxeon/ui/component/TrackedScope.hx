package haxeon.ui.component;

import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A tracked, independently re-running plain Haxe view body. */
class TrackedScope implements ScopeView {
  static final DefaultStyle = new LayoutStyle();
  final key:String;
  final body:Void->View;
  final style:Null<LayoutStyle>;
  public function new(key:String, body:Void->View, ?style:LayoutStyle) {
    if (key == null || key.length == 0 || body == null) throw "A re-running scope needs a key and body";
    this.key = key;
    this.body = body;
    this.style = style;
  }
  public function scopeKey():String return key;
  public function inputsEqual(previous:ScopeView):Bool {
    if (!Std.isOfType(previous, TrackedScope)) return false;
    var other:TrackedScope = cast previous;
    return body == other.body && (style == other.style || style != null && other.style != null &&
      haxeon.Diff.mask(style, other.style) == 0);
  }
  public function buildBody(context:BuildContext):RenderNode {
    // Description construction can build helper nodes; only the returned body's root owns this identity.
    var reserved = context.deferRootIdentity();
    var result = describe(context, reserved);
    if (result == null) throw "A re-running scope returned no view";
    var root = result.build(context);
    if (style != null) haxeon.Diff.apply(root.layout.style, DefaultStyle, style);
    return root;
  }
  function describe(context:BuildContext, reserved:Null<haxeon.ui.core.WidgetId>):View {
    try {
      var result = body();
      context.restoreRootIdentity(reserved);
      return result;
    } catch (error:Dynamic) {
      context.restoreRootIdentity(reserved);
      throw error;
    }
  }
  public function build(context:BuildContext):RenderNode return context.mountComponent(this);
}
