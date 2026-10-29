import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.HitTest;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.overlays.Dialog;
import haxeon.ui.widgets.text.Text;

/** A real dropdown crossing clipped dock content and a later console panel. */
class PopupOverlayTests {
	public static function run(fonts:FontCollection):Void {
		for (useSelect in [false, true])
			runControl(fonts, useSelect);
	}

	static function runControl(fonts:FontCollection, useSelect:Bool):Void {
		var session = LayoutSession.create();
		var ui = new UiContext(session, fonts);
		var changes = 0;
		var options = [
			new SelectOption("one", "One", "one"),
			new SelectOption("two", "Two", "two"),
			new SelectOption("three", "Three", "three")
		];
		for (index in 3...40)
			options.push(new SelectOption("item-" + index, "Item " + index, "item-" + index));
		var selected = "one";
		var onChange = function(value:String) {
			selected = value;
			changes++;
		};
		var control:View;
		if (useSelect) {
			var select = new Select<String>("overlay-select", options, "one", onChange);
			select.style.width = LayoutAxis.fixed(160);
			control = select;
		} else {
			var combo = new ComboBox<String>("overlay-combo", options, "one", onChange);
			combo.style.width = LayoutAxis.fixed(160);
			control = combo;
		}
		var view = new PopupDockScene(control);
		var frame = new LayoutFrame(400, 280);
		var tree = ui.submit(view, frame);
		tree = ui.submit(view, frame);
		var arrow:RenderNode = null;
		tree.walk(function(node) {
			if (node.semantics != null && node.semantics.label == "Show options")
				arrow = node;
		});
		if (useSelect)
			arrow = tree.children[0].children[0].children[0].children[0];
		if (arrow == null)
			throw "Missing popup trigger";
		var bounds = arrow.globalBounds();
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		tree = ui.submit(view, frame);
		tree = ui.submit(view, frame);
		var option:RenderNode = null;
		tree.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.ListItem && node.semantics.label == "Two")
				option = node;
		});
		if (option == null)
			throw "Missing dropdown option";
		bounds = option.globalBounds();
		var x = bounds.x + bounds.width / 2, y = bounds.y + bounds.height / 2;
		if (y <= 60)
			throw "Dropdown fixture does not cross the clipped dock";
		if (session.hitTest(x, y).indexOf(option.id.value) < 0)
			throw "Native hit testing lost the overlay behind the console or ancestor clip";
		if (HitTest.path(tree, x, y).indexOf(option) < 0)
			throw "Haxe hit testing disagrees with native overlay hit testing";
		var hidden:RenderNode = null;
		tree.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.ListItem && node.semantics.label == "Item 39")
				hidden = node;
		});
		if (hidden == null)
			throw "Missing offscreen option";
		var hiddenBounds = hidden.globalBounds();
		if (session.hitTest(x, hiddenBounds.y + 16).indexOf(hidden.id.value) >= 0)
			throw "Offscreen native option escaped its own scroll viewport";
		if (HitTest.path(tree, x, hiddenBounds.y + 16).indexOf(hidden) >= 0)
			throw "Offscreen Haxe option escaped its own scroll viewport";
		var optionId = option.id.value;
		view.modal = true;
		tree = ui.submit(view, frame);
		if (session.hitTest(x, y).indexOf(optionId) >= 0)
			throw "Background dropdown escaped a later modal dialog";
		for (node in HitTest.path(tree, x, y))
			if (node.id.value == optionId)
				throw "Haxe hit testing put a background dropdown above the modal";
		view.modal = false;
		tree = ui.submit(view, frame);
		ui.pointerDown(x, y, 0);
		ui.pointerUp(x, y, 0);
		ui.submit(view, frame);
		if (selected != "two" || changes != 1)
			throw "Overlay click did not select exactly once";
		ui.dispose();
		Sys.println("PASS: " + (useSelect ? "Select" : "ComboBox") + " overlays clipped dock panels, preserves modal order and selects exactly once");
	}
}

private class PopupDockScene implements View {
	public var modal:Bool = false;

	final control:View;

	public function new(control:View)
		this.control = control;

	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		var root = new RenderNode(context.id("dock-root"), LayoutVisualKind.Box, style);
		var dockStyle = new LayoutStyle();
		dockStyle.positioning = LayoutPositioning.Absolute;
		dockStyle.width = LayoutAxis.fixed(250);
		dockStyle.height = LayoutAxis.fixed(60);
		dockStyle.clipVertical = true;
		var dock = new RenderNode(context.id("dock"), LayoutVisualKind.Box, dockStyle);
		var clipStyle = dockStyle.copy();
		clipStyle.positioning = LayoutPositioning.Flow;
		var clipped = new RenderNode(context.id("clipped-dock-content"), LayoutVisualKind.Box, clipStyle);
		clipped.add(control.build(context));
		dock.add(clipped);
		root.add(dock);
		var consoleStyle = new LayoutStyle();
		consoleStyle.positioning = LayoutPositioning.Absolute;
		consoleStyle.positionY = 60;
		consoleStyle.zIndex = 1000;
		consoleStyle.width = LayoutAxis.fixed(400);
		consoleStyle.height = LayoutAxis.fixed(220);
		consoleStyle.background = Color.rgba(0.8, 0.8, 0.8, 1);
		root.add(new RenderNode(context.id("console"), LayoutVisualKind.Box, consoleStyle));
		if (modal)
			root.add(new Dialog("overlay-modal", "Modal", new Text("Modal content"), null, 200).build(context));
		return root;
	}
}
