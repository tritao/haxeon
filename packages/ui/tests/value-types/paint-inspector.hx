import haxeon.ui.Color;
import haxeon.ui.PaintBindings;
import haxeon.ui.PaintStore;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.debug.UiInspector;

function main():Int {
	scoped var paint = new PaintStore();
	var node = new RenderNode(new WidgetId(42)), index = paint.acquire();
	var binding = PaintBindings.attach(node.layout, paint, index);
	node.layout.style.background = Color.rgba(0.125, 0.25, 0.5, 1);
	node.layout.textColor = Color.rgba(0.75, 0.5, 0.25, 1);
	node.layout.style.radiusTopLeft = 2.5;
	var snapshot = UiInspector.nodeSnapshot(node, null), dump = UiInspector.dump(node, null);
	if (snapshot.background.red != 0.125 || snapshot.textColor.red != 0.75 || snapshot.radiusTopLeft != 2.5 ||
		dump.indexOf("background=(0.125,0.25,0.5,1") < 0 || dump.indexOf("radii=(2.5,") < 0) return 1;
	if (!RenderNode.styleFieldsClassified()) return 2;
	PaintBindings.detach(binding);
	paint.release(index, binding.generation);
	return 42;
}
