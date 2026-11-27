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
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.AccessibilityRequest.AccessibilityRequestAction;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.Slider;

/** A caller that keeps its values in plain fields, as most applications do. */
private class PlainPanel implements View {
	public var level = 0.5;
	public var advanced = false;
	public var builds = 0;

	public function new() {}

	public function build(context:BuildContext):ViewRoot {
		builds++;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(300);
		style.height = LayoutAxis.fixed(200);
		style.direction = LayoutDirection.TopToBottom;
		var root = context.createNode(context.rootId("panel"), LayoutVisualKind.Box, style);
		root.add(new Slider("level", "", level, 0.0, 1.0, 0.1, next -> level = next).build(context));
		root.add(new Checkbox("advanced", "", advanced, next -> advanced = next).build(context));
		if (advanced) {
			var marker = context.createNode(context.rootId("advanced-section"), LayoutVisualKind.Box,
				new LayoutStyle());
			marker.styleType = "advanced-section";
			root.add(marker);
		}
		return root;
	}
}

/** Value controls are caller-owned scopes: an edit shows at once, and the caller's value wins when it changes. */
class ControlScopesMain {
	static function find(root:Null<RenderNode>, type:String):Null<RenderNode> {
		var found:Null<RenderNode> = null;
		if (root != null) root.walk(node -> if (found == null && node.styleType == type) found = node);
		return found;
	}

	static function sliderValue(ui:UiContext):Float {
		var slider = find(ui.root, "slider");
		var semantics:Null<Semantics> = slider == null ? null : cast slider.semantics;
		return semantics == null ? -1.0 : semantics.numericValue;
	}

	static function main():Int return run();

	public static function run():Int {
		var ui = new UiContext(LayoutSession.create());
		ui.verifyRetentionEvery = 1;
		var frame = new LayoutFrame(300, 200);
		var panel = new PlainPanel();
		function build():View return panel;
		ui.submitCached(build, frame, "panel");
		if (sliderValue(ui) != 0.5) return 1;
		var slider = find(ui.root, "slider");
		if (slider == null
			|| !ui.accessibilityAction(slider.id.value, AccessibilityRequestAction.Increment, null, -1, -1, 1))
			return 2;
		if (Math.abs(panel.level - 0.6) > 1e-9) return 3;
		var before = panel.builds;
		ui.submitCached(build, frame, "panel");
		// The edit reruns only the slider; the caller's plain field is not read again.
		if (Math.abs(sliderValue(ui) - 0.6) > 1e-9) return 4;
		if (panel.builds - before > 1) return 5;

		var checkbox = find(ui.root, "checkbox");
		if (checkbox == null
			|| !ui.accessibilityAction(checkbox.id.value, AccessibilityRequestAction.Activate, null, -1, -1, 1))
			return 6;
		if (!panel.advanced) return 7;
		ui.submitCached(build, frame, "panel");
		// Activation reruns the enclosing build too, which branches on the caller's plain field.
		if (find(ui.root, "advanced-section") == null) return 8;

		panel.level = 0.2;
		ui.submitCached(build, frame, "panel-reset");
		if (Math.abs(sliderValue(ui) - 0.2) > 1e-9) return 9;
		ui.dispose();
		return 42;
	}
}
