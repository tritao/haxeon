package haxeon.ui.widgets;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.host.WindowControls;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/** Invisible native resize regions, disabled while maximized or fullscreen. */
class WindowFrame implements View {
	final key:String;
	final child:View;
	final controls:WindowControls;
	public function new(key:String, child:View, controls:WindowControls) {
		this.key = key; this.child = child; this.controls = controls;
	}
	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
			var root = new RenderNode(context.id("frame"), LayoutVisualKind.Box, style);
			root.add(child.build(context));
			if (controls.maximized || controls.fullscreen) return root;
			var w = context.viewportWidth, h = context.viewportHeight;
			var edge = 4.0, corner = 8.0;
			function region(id:String, x:Float, y:Float, width:Float, height:Float, kind:WindowDecorationRegionKind):Void {
				var regionStyle = new LayoutStyle(); regionStyle.positioning = LayoutPositioning.Absolute;
				regionStyle.positionX = x; regionStyle.positionY = y;
				regionStyle.width = LayoutAxis.fixed(Math.max(0, width)); regionStyle.height = LayoutAxis.fixed(Math.max(0, height));
				var node = new RenderNode(context.id(id), LayoutVisualKind.Box, regionStyle);
				node.hitTestSelf = false; node.setWindowDecoration(kind); root.add(node);
			}
			region("north", corner, 0, w - 2 * corner, edge, WindowDecorationRegionKind.ResizeNorth);
			region("south", corner, h - edge, w - 2 * corner, edge, WindowDecorationRegionKind.ResizeSouth);
			region("west", 0, corner, edge, h - 2 * corner, WindowDecorationRegionKind.ResizeWest);
			region("east", w - edge, corner, edge, h - 2 * corner, WindowDecorationRegionKind.ResizeEast);
			region("nw", 0, 0, corner, corner, WindowDecorationRegionKind.ResizeNorthwest);
			region("ne", w - corner, 0, corner, corner, WindowDecorationRegionKind.ResizeNortheast);
			region("sw", 0, h - corner, corner, corner, WindowDecorationRegionKind.ResizeSouthwest);
			region("se", w - corner, h - corner, corner, corner, WindowDecorationRegionKind.ResizeSoutheast);
			return root;
		});
	}
}
