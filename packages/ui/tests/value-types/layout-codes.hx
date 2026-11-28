import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutTransaction;

function main():Int {
	var kinds = [LayoutVisualKind.Box, LayoutVisualKind.Text, LayoutVisualKind.Image, LayoutVisualKind.Custom];
	for (index in 0...kinds.length) {
		if (kinds[index].rawValue != index + 1) return 3;
	}
	var style = new LayoutStyle();
	style.width = LayoutAxis.fixed(42);
	style.height = LayoutAxis.grow(3, 90, 2);
	if (style.width != LayoutAxis.fixed(42) || haxeon.Diff.mask(style, style.copy()) != 0) return 5;
	var bytes = LayoutTransaction.encode(new LayoutNode(1, LayoutVisualKind.Image, style));
	var record = NativeKitUIConstants.NKUI_LAYOUT_TRANSACTION_HEADER_BYTES;
	if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET) != 3) return 6;
	return 42;
}
