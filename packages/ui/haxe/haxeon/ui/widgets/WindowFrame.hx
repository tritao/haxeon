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
	/** Logical coordinates: resize targets remain usable without scaling with editor zoom. */
	static function resizeRegions(w:Float, h:Float):Array<WindowResizeRegion> {
		if (w <= 0 || h <= 0) return [];
		var edgeX = Math.min(6.0, w / 2), edgeY = Math.min(6.0, h / 2);
		var cornerX = Math.min(20.0, w / 2), cornerY = Math.min(20.0, h / 2);
		var result:Array<WindowResizeRegion> = [];
		function add(id:String, x:Float, y:Float, width:Float, height:Float, kind:WindowDecorationRegionKind):Void {
			if (width > 0 && height > 0) result.push({id:id, x:x, y:y, width:width, height:height, kind:kind});
		}
		add("north", cornerX, 0, w - 2 * cornerX, edgeY, WindowDecorationRegionKind.ResizeNorth);
		add("south", cornerX, h - edgeY, w - 2 * cornerX, edgeY, WindowDecorationRegionKind.ResizeSouth);
		add("west", 0, cornerY, edgeX, h - 2 * cornerY, WindowDecorationRegionKind.ResizeWest);
		add("east", w - edgeX, cornerY, edgeX, h - 2 * cornerY, WindowDecorationRegionKind.ResizeEast);
		// L-shaped corners extend along the rim without stealing interior controls.
		add("nw-top", 0, 0, cornerX, edgeY, WindowDecorationRegionKind.ResizeNorthwest);
		add("nw-side", 0, edgeY, edgeX, cornerY - edgeY, WindowDecorationRegionKind.ResizeNorthwest);
		add("ne-top", w - cornerX, 0, cornerX, edgeY, WindowDecorationRegionKind.ResizeNortheast);
		add("ne-side", w - edgeX, edgeY, edgeX, cornerY - edgeY, WindowDecorationRegionKind.ResizeNortheast);
		add("sw-bottom", 0, h - edgeY, cornerX, edgeY, WindowDecorationRegionKind.ResizeSouthwest);
		add("sw-side", 0, h - cornerY, edgeX, cornerY - edgeY, WindowDecorationRegionKind.ResizeSouthwest);
		add("se-bottom", w - cornerX, h - edgeY, cornerX, edgeY, WindowDecorationRegionKind.ResizeSoutheast);
		add("se-side", w - edgeX, h - cornerY, edgeX, cornerY - edgeY, WindowDecorationRegionKind.ResizeSoutheast);
		return result;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
			var root = new RenderNode(context.id("frame"), LayoutVisualKind.Box, style);
			root.add(child.build(context));
			if (controls.maximized || controls.fullscreen) return root;
			for (region in resizeRegions(context.viewportWidth, context.viewportHeight)) {
				var regionStyle = new LayoutStyle(); regionStyle.positioning = LayoutPositioning.Absolute;
				regionStyle.positionX = region.x; regionStyle.positionY = region.y;
				regionStyle.width = LayoutAxis.fixed(region.width); regionStyle.height = LayoutAxis.fixed(region.height);
				var node = new RenderNode(context.id(region.id), LayoutVisualKind.Box, regionStyle);
				node.hitTestSelf = false; node.setWindowDecoration(region.kind); root.add(node);
			}
			return root;
		});
	}
}

private typedef WindowResizeRegion = {
	var id:String;
	var x:Float;
	var y:Float;
	var width:Float;
	var height:Float;
	var kind:WindowDecorationRegionKind;
}
