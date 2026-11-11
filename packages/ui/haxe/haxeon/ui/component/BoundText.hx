package haxeon.ui.component;

import haxeon.reactive.Effect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/** Mount a text node and update its value from a tracked getter. */
class BoundText implements View {
  final key:String;
  final read:Void->String;
  public function new(key:String, read:Void->String) {
    if (key == null || key.length == 0 || read == null)
      throw "A text binding needs a key and getter";
    this.key = key;
    this.read = read;
  }
  public function build(context:BuildContext):RenderNode {
    var state:State<TextBinding> = context.resourceState(context.id("bound-text:" + key),
      () -> new TextBinding(context, read, context.requestBindingFrame), binding -> binding.dispose());
    var binding = state.value;
    binding.rebind(read);
    var node = new Text(binding.value).build(context);
    binding.attach(node);
    return node;
  }
}

private class TextBinding {
  final context:BuildContext;
  var read:Void->String;
  var node:Null<RenderNode>;
  var attached:Bool = false;
  final effect:Effect;
  public var value(default, null):String = "";

  public function new(context:BuildContext, read:Void->String, schedule:Void->Void) {
    this.context = context;
    this.read = read;
    effect = new ScheduledBindingEffect(update, schedule);
  }
  function update():Void {
    var next = read();
    if (next == null) next = "";
    if (value == next) return;
    value = next;
    var current = node == null ? null : RenderNode.latest(node);
    if (current != null) {
      context.willEditRetained(current);
      current.layout.text = next;
      if (current.semantics != null) current.semantics.label = next;
    }
  }
  public function rebind(next:Void->String):Void {
    if (!attached) { read = next; return; }
    node = null;
    read = next;
    effect.retrack();
  }
  public function attach(next:RenderNode):Void { node = next; attached = true; }
  public function dispose():Void {
    node = null;
    effect.dispose();
  }
}

private class ScheduledBindingEffect extends Effect {
  final schedule:Void->Void;
  public function new(update:Void->Void, schedule:Void->Void) {
    this.schedule = schedule;
    super(update);
  }
  override public function onMaybeStale():Void {
    super.onMaybeStale();
    schedule();
  }
}
