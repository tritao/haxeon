import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.controls.IconButton;

/** A component that counts how often its body runs. */
private class Counted implements ScopeView {
	public static var runs = 0;

	final label:String;
	final own:Signal<Int>;

	public function new(label:String, own:Signal<Int>) {
		this.label = label;
		this.own = own;
	}

	public function scopeKey():String return "counted";

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Counted)) return false;
		var other:Counted = cast previous;
		return label == other.label && own == other.own;
	}

	public function buildBody(context:BuildContext):ViewRoot {
		runs++;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(20 + own.value);
		style.height = LayoutAxis.fixed(20);
		var node = context.createNode(context.rootId("counted"), LayoutVisualKind.Box, style);
		node.styleType = "counted-" + label;
		return node;
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);
}

private class Parent implements View {
	public final outer = new Signal<Int>(0);
	public final own = new Signal<Int>(0);
	public var label = "a";
	public var builds = 0;

	public function new() {}

	public function build(context:BuildContext):ViewRoot {
		builds++;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(200 + outer.value);
		style.height = LayoutAxis.fixed(100);
		var root = context.createNode(context.rootId("parent"), LayoutVisualKind.Box, style);
		root.add(new Counted(label, own).build(context));
		return root;
	}
}

/** A caller that passes a new callback on every run, as most do. */
private class ClickParent implements View {
	public final outer = new Signal<Int>(0);
	public var generation = 0;
	public var clicked = -1;

	public function new() {}

	public function build(context:BuildContext):ViewRoot {
		var run = ++generation;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(200 + outer.value);
		style.height = LayoutAxis.fixed(100);
		var root = context.createNode(context.rootId("click-parent"), LayoutVisualKind.Box, style);
		root.add(new IconButton("go", IconName.Check, "Go", () -> clicked = run).build(context));
		return root;
	}
}

/** A parent run that describes a component with equal inputs keeps its body; changed inputs and its own reads rerun it. */
class ScopeSkipMain {
	static function counted(ui:UiContext):Null<RenderNode> {
		var root = ui.root;
		return root == null || root.children.length != 1 ? null : root.children[0];
	}

	static function main():Int return run();

	public static function run():Int {
		var ui = new UiContext(LayoutSession.create());
		var frame = new LayoutFrame(300, 200);
		var parent = new Parent();
		function build():View return parent;
		Counted.runs = 0;
		ui.submitCached(build, frame, "skip");
		var first = counted(ui);
		if (first == null || Counted.runs != 1) return 1;
		parent.outer.value = 1;
		ui.submitCached(build, frame, "skip");
		if (parent.builds != 2) return 2;
		if (Counted.runs != 1 || counted(ui) != first) return 3;
		parent.own.value = 5;
		ui.submitCached(build, frame, "skip");
		var rerun = counted(ui);
		if (Counted.runs != 2 || rerun == null || rerun.layout.style.width.value != 25) return 4;
		parent.label = "b";
		parent.outer.value = 2;
		ui.submitCached(build, frame, "skip");
		var relabelled = counted(ui);
		if (Counted.runs != 3 || relabelled == null || relabelled.styleType != "counted-b") return 5;
		parent.outer.value = 3;
		ui.submitCached(build, frame, "skip");
		if (Counted.runs != 3 || counted(ui) != relabelled) return 6;
		if (ui.verifyRetention(build, frame) != null) return 7;
		ui.dispose();
		return callbacks();
	}

	/** A new callback alone keeps the body, which then calls the newest one. */
	static function callbacks():Int {
		var ui = new UiContext(LayoutSession.create());
		var frame = new LayoutFrame(300, 200);
		var parent = new ClickParent();
		function build():View return parent;
		ui.submitCached(build, frame, "click");
		var root = ui.root;
		var button = root == null ? null : root.children[0];
		if (button == null) return 20;
		parent.outer.value = 1;
		ui.submitCached(build, frame, "click");
		root = ui.root;
		if (parent.generation != 2 || root == null || root.children[0] != button) return 21;
		var bounds = button.globalBounds();
		ui.pointerDown(bounds.x + 2, bounds.y + 2, 0);
		ui.pointerUp(bounds.x + 2, bounds.y + 2, 0);
		if (parent.clicked != 2) return 22;
		ui.dispose();
		return 42;
	}
}
