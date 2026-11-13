package haxeon.ui.component;

import haxeon.ui.core.LiveTextBinding;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.LayoutStyle;
import haxeon.ui.widgets.text.Text;

/** Mount a text node and update its value from a tracked getter. */
class BoundText implements View {
  final key:String;
  final read:Void -> String;
  public function new(key:String, read:Void -> String) {
    if (key == null || key.length == 0 || read == null) throw "A text binding needs a key and getter";
    this.key = key;
    this.read = read;
  }
  public function build(context:BuildContext):RenderNode {
    var state:State<LiveTextBinding> = context.resourceState(
      context.id("bound-text:" + key),
      () -> new LiveTextBinding(read, context),
      binding -> binding.dispose()
    );
    var binding = state.value;
    binding.rebind(read);
    var node = new BoundTextPrimitive(binding.value).build(context);
    binding.attach(cast node);
    return node;
  }
}

private class BoundTextPrimitive extends Text {
  public function new(value:String) super(value);
  override function createNode(context:BuildContext, id:WidgetId, style:LayoutStyle):RenderNode {
    return context.createLiveTextNode(id, style, value);
  }
}
