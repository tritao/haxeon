import haxeon.platform.Runtime;
import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;

/** Root factory dependencies must survive the focus feedback of a modal menu. */
class FocusFeedbackTests {
	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function menuCount(root:RenderNode):Int {
		var count = 0;
		root.walk(node -> {
			if (node.semantics != null && node.semantics.label == "Menu")
				count++;
		});
		return count;
	}

	public static function main():Int {
		var runtime = Runtime.start();
		var fonts = FontCollection.create();
		fonts.addSystemFallbacks();
		var ui = new UiContext(null, fonts), open = new Signal(false);
		var frame = new LayoutFrame(400, 300);
		var build = function():View {
			if (!open.value)
				return new Button("Add", null, () -> open.value = true, "add");
			return new Menu("menu", [new MenuItem("item", "Item", () -> {})], 30, 40, () -> open.value = false);
		};
		function submit():RenderNode
			return ui.submitCached(build, frame, "stable");
		check(menuCount(submit()) == 0, "menu starts closed");
		for (cycle in 0...12) {
			open.value = true;
			check(menuCount(submit()) == 1, "opening must show the menu: " + cycle);
			check(ui.focus.focusedId != null, "menu owns keyboard focus");
			ui.key(UiEventKind.KeyDown, UiKey.Escape);
			check(!open.value, "Escape changes the visibility model");
			check(menuCount(submit()) == 0, "focus feedback must retain the visibility dependency: " + cycle);
			// An idle cached submission must preserve tracking for the next open.
			check(menuCount(submit()) == 0, "idle cached frame stays closed");
		}
		ui.dispose();
		fonts.dispose();
		runtime.dispose();
		Sys.println("Focus feedback: repeated modal open/close passed");
		return 0;
	}
}
