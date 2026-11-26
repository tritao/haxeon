import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;

private class Body implements ScopeView {
	final size:Signal<Int>;

	public function new(size:Signal<Int>) this.size = size;

	public function scopeKey():String return "body";

	public function inputsEqual(previous:ScopeView):Bool return false;

	public function buildBody(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(size.value);
		style.height = LayoutAxis.fixed(20);
		var node = context.createNode(context.rootId("body"), LayoutVisualKind.Box, style);
		node.styleType = "body";
		return node;
	}

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);
}

private class Caller implements View {
	public final size = new Signal<Int>(30);
	public final outer = new Signal<Int>(0);
	public var stretch = true;
	public var clicks = 0;

	public function new() {}

	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(200 + outer.value);
		style.height = LayoutAxis.fixed(100);
		var root = context.createNode(context.rootId("caller"), LayoutVisualKind.Box, style);
		var modifier = new RootModifier();
		if (stretch) modifier.width = LayoutAxis.grow();
		modifier.on(UiEventKind.Click, _ -> clicks++);
		var badge = context.createNode(context.rootId("badge"), LayoutVisualKind.Box, new LayoutStyle());
		badge.styleType = "badge";
		modifier.add(badge);
		root.add(context.build(new Body(size), modifier));
		return root;
	}
}

/** A caller's modifier stays on a component root through reruns of its body and comes off when the caller drops it. */
class RootModifierMain {
	static function body(ui:UiContext):Null<RenderNode> {
		var root = ui.root;
		return root == null || root.children.length != 1 ? null : root.children[0];
	}

	static function badges(node:RenderNode):Int {
		var count = 0;
		for (child in node.children) if (child.styleType == "badge") count++;
		return count;
	}

	static function main():Int return run();

	public static function run():Int {
		var ui = new UiContext(LayoutSession.create());
		ui.verifyRetentionEvery = 1;
		ui.buildContext.checkComponentRoots = true;
		var frame = new LayoutFrame(300, 200);
		var caller = new Caller();
		function build():View return caller;
		ui.submitCached(build, frame, "modifier");
		var first = body(ui);
		if (first == null || first.layout.style.width.sizing != LayoutSizing.Grow || badges(first) != 1) return 1;
		// The body reruns alone: the modifier moves to its new root once, with its listener and child.
		caller.size.value = 40;
		ui.submitCached(build, frame, "modifier");
		var rerun = body(ui);
		if (rerun == null || rerun.layout.style.width.sizing != LayoutSizing.Grow || badges(rerun) != 1) return 2;
		var bounds = rerun.globalBounds();
		ui.pointerDown(bounds.x + 2, bounds.y + 2, 0);
		ui.pointerUp(bounds.x + 2, bounds.y + 2, 0);
		if (caller.clicks != 1) return 3;
		// The caller drops the width: the body's own fixed width shows again.
		caller.stretch = false;
		caller.outer.value = 1;
		ui.submitCached(build, frame, "modifier");
		var plain = body(ui);
		if (plain == null || plain.layout.style.width.sizing != LayoutSizing.Fixed
			|| plain.layout.style.width.value != 40
			|| badges(plain) != 1) return 4;
		ui.dispose();
		return 42;
	}
}
