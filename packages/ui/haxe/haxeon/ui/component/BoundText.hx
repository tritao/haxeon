package haxeon.ui.component;

import haxeon.reactive.Effect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;
import haxeon.ui.core.LiveTextNode;
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
    var state:State<TextBinding> = context.resourceState(
      context.id("bound-text:" + key),
      () -> new TextBinding(read, context.requestBindingFrame),
      binding -> binding.dispose()
    );
    var binding = state.value;
    binding.rebind(read);
    var node = new BoundTextPrimitive(binding.value).build(context);
    binding.attach(cast node);
    return node;
  }
}

private class TextBinding {
  var read:Void -> String;
  var node:Null<LiveTextNode>;
  var attached:Bool = false;
  final effect:Effect;
  public var value(default, null):String = "";

  public function new(read:Void -> String, schedule:Void -> Void) {
    this.read = read;
    effect = new ScheduledBindingEffect(update, schedule);
  }
  function update():Void {
    var next = read();
    if (next == null) next = "";
    if (value == next) return;
    value = next;
    if (node != null) node.setText(next);
  }
  public function rebind(next:Void -> String):Void {
    if (!attached) {
      read = next;
      return;
    }
    var previousNode = node, previousRead = read;
    node = null;
    read = next;
    try effect.retrack() catch (error:Dynamic) {
      node = previousNode;
      read = previousRead;
      // Failed tracking drops untouched inputs. Reconnect the installed getter before returning its replacement's error.
      try effect.retrack() catch (_:Dynamic) {
      }
      throw error;
    }
  }
  public function attach(next:LiveTextNode):Void {
    node = next;
    attached = true;
  }
  public function dispose():Void {
    node = null;
    effect.dispose();
  }
}

private class BoundTextPrimitive extends Text {
  public function new(value:String) super(value);
  override function createNode(context:BuildContext, id:WidgetId, style:LayoutStyle):RenderNode {
    return context.createLiveTextNode(id, style, value);
  }
}

private class ScheduledBindingEffect extends Effect {
  final schedule:Void -> Void;
  public function new(update:Void -> Void, schedule:Void -> Void) {
    this.schedule = schedule;
    super(update);
  }
  override public function onMaybeStale():Void {
    super.onMaybeStale();
    schedule();
  }
}
