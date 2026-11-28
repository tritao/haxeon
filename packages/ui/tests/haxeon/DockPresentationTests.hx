import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockWorkspace;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.widgets.text.Text;

class DockPresentationTests {
	static function require(ok:Bool, message:String):Void {
		if (!ok) throw message;
	}
	static function has(root:RenderNode, label:String):Bool {
		var found = false;
		root.walk(function(n) {
			if (n.semantics != null && n.semantics.label == label) found = true;
		});
		return found;
	}
	public static function run(context:UiContext):Void {
		var model = new DockWorkspaceModel();
		for (id in ["nav", "main", "right"]) model.register(new DockPanelDescriptor(id, id));
		// The workspace is described again for each set of panels it hides.
		function view(hiddenPanels:Array<String>):DockWorkspace
			return new DockWorkspace("presentation-test", model, [
				new DockPanelContent("nav", function(_) return new Text("NAV CONTENT")),
				new DockPanelContent("main", function(_) return new Text("MAIN CONTENT")),
				new DockPanelContent("right", function(_) return new Text("RIGHT CONTENT"))
			], hiddenPanels:);
		model.setRoot(DockNode.Split(Horizontal, 0.25, Panel("nav"),
			Split(Horizontal, 0.6, Panel("main"), Panel("right"))));
		var saved = model.snapshotJson();
		var root = context.submit(view(["right"]), new LayoutFrame(1000, 400));
		require(has(root, "MAIN CONTENT") && has(root, "NAV CONTENT") && !has(root, "RIGHT CONTENT"),
			"Suppressed dock panel remained visible");
		require(model.snapshotJson() == saved, "Presentation suppression changed the saved dock tree");
		// Hiding the first branch keeps the surviving divider's original model path.
		root = context.submit(view(["nav"]), new LayoutFrame(1000, 400));
		var divider:RenderNode = null;
		root.walk(function(n) {
			if (n.styleType == "split-divider") divider = n;
		});
		if (divider == null) throw "Surviving dock split lost its divider";
		var b = divider.globalBounds();
		context.pointerDown(b.x + b.width / 2, b.y + 100, 0);
		context.pointerMove(b.x + b.width / 2 - 40, b.y + 100);
		context.pointerUp(b.x + b.width / 2 - 40, b.y + 100, 0);
		switch model.root {
			case Split(Horizontal, outer, _, Split(Horizontal, inner, _, _)):
				require(outer == 0.25 && inner < 0.6, "Projected divider updated the wrong persisted split");
			case _: throw "Projected divider changed the dock structure";
		}
		model.setRoot(Tabs(["main", "right"], "right"));
		saved = model.snapshotJson();
		root = context.submit(view(["right"]), new LayoutFrame(1000, 400));
		require(has(root, "MAIN CONTENT") && !has(root, "RIGHT CONTENT") && model.snapshotJson() == saved,
			"Suppressed active tab changed persisted selection or failed to fall back");
		root = context.submit(view([]), new LayoutFrame(1000, 400));
		require(has(root, "RIGHT CONTENT"), "Restored tab lost its original active selection");
		model.setRoot(Panel("right"));
		root = context.submit(view(["right"]), new LayoutFrame(1000, 400));
		require(!has(root, "RIGHT CONTENT"), "Fully suppressed dock root was still visible");
		Sys.println("PASS: presentation-only dock suppression, tab fallback, original divider paths and restoration");
	}
}
