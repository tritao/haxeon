package haxeon.ui.component;

import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A tracked, independently re-running plain Haxe view body. */
class TrackedScope implements View {
  final key:String;
  final body:Void->View;
  final style:Null<LayoutStyle>;
  public function new(key:String, body:Void->View, ?style:LayoutStyle) {
    if (key == null || key.length == 0 || body == null) throw "A re-running scope needs a key and body";
    this.key = key;
    this.body = body;
    this.style = style;
  }
  public function build(context:BuildContext):RenderNode {
    return context.withScope(new Key(key), () -> {
      var id = context.id("scope");
      return context.selfUpdating(id, () -> {
        var result = body();
        if (result == null) throw "A re-running scope returned no view";
        var root = new RenderNode(id, LayoutVisualKind.Box, style);
        root.add(result.build(context));
        return root;
      }, false);
    });
  }
}
