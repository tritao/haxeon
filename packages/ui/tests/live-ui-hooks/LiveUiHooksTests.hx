import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;

/** Two focusable boxes; the first runs `handler` when clicked, as the app's current code would install it. */
private class ButtonsView implements View {
	public var handler:UiEvent->Void;
	public function new(handler:UiEvent->Void) this.handler = handler;
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(120);
		style.height = LayoutAxis.fixed(40);
		var root = new Column("buttons", [
			new KeyedView("first", new CanvasView("first", function(_, _) {}, style, "First")),
			new KeyedView("second", new CanvasView("second", function(_, _) {}, style, "Second"))
		]).build(context);
		for (child in root.children) child.focusable = true;
		root.children[0].on(UiEventKind.Click, handler);
		return root;
	}
}

/**
 * What a live host relies on from `UiContext.releaseRetained`: the context lets go of the tree and its handlers, input
 * between release and the next submit is harmless, and the next submit builds afresh with the handlers the code now
 * installs, keeping focus by ID.
 */
class LiveUiHooksTests {
	static function check(value:Bool, message:String):Void if (!value) throw message;

	static function click(context:UiContext):Void {
		context.pointerMove(10, 10);
		context.pointerDown(10, 10, 0);
		context.pointerUp(10, 10, 0);
	}

	static function main():Int {
		var context = new UiContext();
		var oldClicks = 0, newClicks = 0, builds = 0;
		var view = new ButtonsView(function(_) oldClicks++);
		var build = function():View { builds++; return view; };
		var frame = new LayoutFrame(240, 160);
		var root = context.submitCached(build, frame, "buttons");
		var second = root.children[1].id;
		click(context);
		check(oldClicks == 1, "the first build's handler must run");
		check(context.focusWidget(second), "focus the second box");
		context.submitCached(build, frame, "buttons");
		check(builds == 1 || builds == 2, "a cached submit may reuse the tree");
		var buildsBeforeRelease = builds;

		context.releaseRetained();
		check(context.root == null, "release must drop the root");
		check(context.inspect().length == 0, "release must leave no inspectable tree");
		check(context.events.hitTestPath(10, 10).length == 0, "release must leave nothing to hit");
		check(context.focus.focusedNode() == null, "release must drop the focus order's nodes");
		check(context.focus.focusedId != null && context.focus.focusedId.equals(second), "release must keep focus by ID");

		// Input between release and rebuild finds no target and must not reach the released handlers.
		click(context);
		context.scroll(10, 10, 0, 20);
		context.key("down", 9);
		context.key("up", 9);
		context.text("commit", "x");
		context.pointerLeave();
		check(oldClicks == 1, "a released handler must not run");
		check(context.focus.focusedId != null && context.focus.focusedId.equals(second), "input before rebuild must keep focus by ID");
		// A window blur and refocus before the rebuild hands the focus to the next submit.
		context.windowFocusLost();
		context.windowFocusGained();

		// The patched code installs a new handler; the same cache key must still build afresh.
		view.handler = function(_) newClicks++;
		root = context.submitCached(build, frame, "buttons");
		check(builds == buildsBeforeRelease + 1, "the submit after release must build, not reuse the released tree");
		check(context.root == root && root.children.length == 2, "the rebuilt tree must be the context's root");
		check(context.focus.focusedId != null && context.focus.focusedId.equals(second), "focus must come back by ID");
		click(context);
		check(newClicks == 1 && oldClicks == 1, "the rebuilt tree must run the new handler, not the old one");

		// Releasing twice, or releasing a context that never built, is harmless.
		context.releaseRetained();
		context.releaseRetained();
		var fresh = new UiContext();
		fresh.releaseRetained();
		check(fresh.root == null, "a context that never built has no root");
		context.dispose();
		fresh.dispose();
		Sys.println("PASS: UiContext.releaseRetained drops the tree and its handlers, and the next submit rebuilds them");
		return 0;
	}
}
