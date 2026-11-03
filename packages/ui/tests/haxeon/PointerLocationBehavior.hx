import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;

function main():Int {
	var dispatcher = new EventDispatcher(new FocusManager());
	var root = new RenderNode(new WidgetId(1));
	var calls:Array<Float> = [];
	var cancel = false;
	dispatcher.setHitTestProvider(function(x:Float, y:Float):Array<RenderNode> {
		if (cancel) {
			calls.push(x);
			if (x == 10.0) dispatcher.pointerCancel(7, 20.0, 20.0);
		}
		return [];
	});
	dispatcher.setRoot(root);
	dispatcher.pointerMove(10.0, 10.0, 0, 3);
	dispatcher.pointerMove(20.0, 20.0, 0, 7);
	cancel = true;
	dispatcher.setRoot(root);
	if (calls.length != 1 || calls[0] != 10.0) return 1;
	return 42;
}
