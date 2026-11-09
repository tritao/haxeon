import haxeon.ui.core.CursorShape;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import nativekit.ffi.NativeKitTypes.CursorShape as NativeCursorShape;

@:access(haxeon.ui.core.UiContext)
private class CursorShapeProbe {
	public static function run():Int {
		var shapes = [CursorShape.Arrow, CursorShape.Text, CursorShape.Crosshair, CursorShape.Hand,
			CursorShape.HorizontalResize, CursorShape.VerticalResize, CursorShape.DiagonalResize,
			CursorShape.Move, CursorShape.NotAllowed, CursorShape.DiagonalResizeNesw];
		var native = [NativeCursorShape.Arrow, NativeCursorShape.Ibeam, NativeCursorShape.Crosshair,
			NativeCursorShape.Hand, NativeCursorShape.HorizontalResize, NativeCursorShape.VerticalResize,
			NativeCursorShape.NwseResize, NativeCursorShape.Move, NativeCursorShape.NotAllowed, NativeCursorShape.NeswResize];
		var node = new RenderNode(new WidgetId(1));
		if (node.cursor != null || node.windowDecorationCursor != null) return 1;
		for (index in 0...shapes.length) {
			var shape = shapes[index];
			node.cursor = shape;
			node.windowDecorationCursor = shape;
			if (node.cursor != shape || node.windowDecorationCursor != shape) return 2;
			if (UiContext.nativeCursorShape(shape) != native[index]) return 3;
		}
		node.cursor = null;
		node.windowDecorationCursor = null;
		return node.cursor == null && node.windowDecorationCursor == null ? 42 : 4;
	}
}

function main():Int return CursorShapeProbe.run();
