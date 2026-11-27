import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.widgets.navigation.BottomSheet;
import haxeon.ui.widgets.navigation.NavigationController;
import haxeon.ui.widgets.navigation.NavigationStack;

private class Screen implements View {
	final name:String;

	public function new(name:String) this.name = name;

	public function build(context:BuildContext):ViewRoot {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(40);
		style.height = LayoutAxis.fixed(40);
		var node = context.createNode(context.rootId(name), LayoutVisualKind.Box, style);
		node.styleType = "screen-" + name;
		return node;
	}
}

/** Sheet and stack motion reruns only the widget's own scope, and each frame matches a fresh build. */
class NavigationScopesMain {
	static function find(root:RenderNode, type:String):Null<RenderNode> {
		var found:Null<RenderNode> = null;
		root.walk(node -> if (found == null && node.styleType == type) found = node);
		return found;
	}

	static function panelY(ui:UiContext):Float {
		var root = ui.root;
		var panel = root == null ? null : find(root, "bottom-sheet-panel");
		if (panel == null) return -1.0;
		var transform = panel.layout.style.transform;
		return transform == null ? 0.0 : transform.ty;
	}

	static function main():Int return run();

	public static function run():Int {
		var ui = new UiContext(LayoutSession.create());
		ui.verifyRetentionEvery = 1;
		var frame = new LayoutFrame(300, 400);
		var builds = 0;
		var dismissed = 0;
		var sheet:View = new BottomSheet("sheet", "", new Screen("body"), () -> dismissed++);
		function buildSheet():View {
			builds++;
			return sheet;
		}
		ui.submitCached(buildSheet, frame, "sheet");
		var start = panelY(ui);
		if (start <= 0.0) return 1;
		var outer = builds;
		frame.deltaSeconds = 0.05;
		for (_ in 0...20) ui.submitCached(buildSheet, frame, "sheet");
		if (panelY(ui) != 0.0) return 2;
		// Verification builds again every frame; the animation itself needs no outer build.
		if (builds - outer > 20) return 3;
		if (dismissed != 0) return 4;

		var controller = new NavigationController({id: "home", build: () -> new Screen("home")});
		var stack:View = new NavigationStack("screens", controller);
		function buildStack():View return stack;
		frame.deltaSeconds = 0.0;
		ui.submitCached(buildStack, frame, "stack");
		var root = ui.root;
		if (root == null || find(root, "screen-home") == null) return 5;
		// The controller is observable: the push reruns the stack without a new outer build.
		controller.push({id: "detail", build: () -> new Screen("detail")});
		ui.submitCached(buildStack, frame, "stack");
		root = ui.root;
		if (root == null || find(root, "screen-detail") == null || find(root, "screen-home") == null) return 6;
		frame.deltaSeconds = 0.05;
		for (_ in 0...20) ui.submitCached(buildStack, frame, "stack");
		root = ui.root;
		if (controller.transitionKind != 0) return 7;
		if (root == null || find(root, "screen-detail") == null || find(root, "screen-home") != null) return 8;
		ui.dispose();
		return 42;
	}
}
