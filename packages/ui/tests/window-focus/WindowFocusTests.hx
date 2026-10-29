import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.WindowStateFlags;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;

private class FocusView implements View {
	public var showFirst = true;
	public var enableFirst = true;
	public var trapSecond = false;
	public function new() {}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(120);
		style.height = LayoutAxis.fixed(40);
		var children:Array<KeyedView> = [];
		if (showFirst) children.push(new KeyedView("first", new CanvasView("first", function(_, _) {}, style, "First")));
		children.push(new KeyedView("second", new CanvasView("second", function(_, _) {}, style, "Second")));
		var root = new Column("focus-test", children).build(context);
		for (child in root.children) child.focusable = true;
		if (showFirst) root.children[0].enabled = enableFirst;
		root.children[root.children.length - 1].focusTrap = trapSecond;
		return root;
	}
}

class WindowFocusTests {
	static function check(value:Bool, message:String):Void if (!value) throw message;
	static function main():Int {
		var context = new UiContext();
		var view = new FocusView();
		var frame = new LayoutFrame(240, 160);
		var root = context.submit(view, frame);
		var first = root.children[0].id, second = root.children[1].id;
		var source = new Handle(17);
		var input = new NativeInputAdapter(context, source);
		var gained = 0, lost = 0;
		root.children[0].on(UiEventKind.Focus, function(_) { gained++; });
		root.children[0].on(UiEventKind.FocusLost, function(_) { lost++; });
		check(context.focusWidget(first), "initial focus");
		input.consume(WindowStateChanged(source, 0));
		input.consume(WindowStateChanged(source, 0));
		check(context.focus.focusedId == null && lost == 1, "loss clears focus once");
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId != null && context.focus.focusedId.equals(first) && gained == 2,
			"window activation must restore the focused widget");
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(gained == 2, "duplicate activation must not refocus");
		// A background frame rebuild must not lose the remembered stable ID.
		input.consume(WindowStateChanged(source, 0));
		context.submit(view, frame);
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId != null && context.focus.focusedId.equals(first), "restore after rebuild");
		input.consume(WindowStateChanged(source, 0));
		context.clearFocus();
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId == null, "explicit clear cancels restoration");
		context.focusWidget(first);
		input.consume(WindowStateChanged(source, 0));
		context.focusWidget(second);
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId.equals(second), "activation must preserve a newer focus choice");
		context.focusWidget(first);
		input.consume(WindowStateChanged(source, 0));
		view.showFirst = false;
		context.submit(view, frame);
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId == null, "removed widget must not regain focus");
		view.showFirst = true;
		context.submit(view, frame);
		context.focusWidget(first);
		input.consume(WindowStateChanged(source, 0));
		view.enableFirst = false;
		context.submit(view, frame);
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId == null, "disabled widget must not regain focus");
		view.enableFirst = true;
		context.submit(view, frame);
		context.focusWidget(first);
		input.consume(WindowStateChanged(source, 0));
		view.trapSecond = true;
		context.submit(view, frame);
		input.consume(WindowStateChanged(source, WindowStateFlags.Active));
		check(context.focus.focusedId != null && context.focus.focusedId.equals(second), "modal focus stays in its trap");
		context.dispose();
		Sys.println("PASS: window focus restoration, duplicate events, rebuilds, explicit changes and eligibility");
		return 0;
	}
}
