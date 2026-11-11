import haxeon.ui.Color;
import haxeon.ui.LayoutNode;
import haxeon.ui.PaintBinding;
import haxeon.ui.PaintBindings;
import haxeon.ui.PaintStore;

class PaintUpdateCensus {
	static var paint:PaintStore;
	static var node:LayoutNode;
	static var binding:PaintBinding;
	public static function prepare():Void {
		paint = new PaintStore();
		node = LayoutNode.box(1);
		var index = paint.acquire();
		binding = PaintBindings.attach(node, paint, index);
	}
	public static function perform(count:Int):Int {
		var total = 0;
		for (index in 0...count) {
			var component = (index & 1) == 0 ? 0.25 : 0.5;
			node.style.background = Color.rgba(component, 0.0, 0.0, 1.0);
			node.style.radiusTopLeft = component;
			node.textColor = Color.rgba(component, 1.0, 1.0, 1.0);
			if (node.style.background.red == component && node.textColor.red == component &&
				node.style.radiusTopLeft == component) total++;
		}
		return total;
	}
	public static function cleanup():Void {
		PaintBindings.detach(binding);
		paint.dispose();
	}
}

function main():Int {
	PaintUpdateCensus.prepare();
	PaintUpdateCensus.perform(1);
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var result = PaintUpdateCensus.perform(1024);
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 2;
	#end
	PaintUpdateCensus.cleanup();
	return result == 1024 ? 42 : 1;
}
