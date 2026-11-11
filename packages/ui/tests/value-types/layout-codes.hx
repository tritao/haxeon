import haxeon.ui.LayoutSizing;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutTransaction;
import haxeon.ui.PaintStore;

function main():Int {
    var sizes = [LayoutSizing.Fit, LayoutSizing.Grow, LayoutSizing.Fixed, LayoutSizing.Percent];
    for (index in 0...sizes.length) {
        if (Type.enumIndex(sizes[index]) != index || haxeon.ui.NativeEnums.layoutSizing(sizes[index]).rawValue() != index) return 1;
    }
    var kinds = [LayoutVisualKind.Box, LayoutVisualKind.Text, LayoutVisualKind.Image, LayoutVisualKind.Custom];
    for (index in 0...kinds.length) {
        if (Type.enumIndex(kinds[index]) != index || haxeon.ui.NativeEnums.layoutVisualKind(kinds[index]).rawValue() != index + 1) return 3;
    }
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(42);
    style.height = LayoutAxis.grow(3, 90, 2);
    if (style.width != LayoutAxis.fixed(42) || haxeon.Diff.mask(style, style.copy()) != 0) return 5;
    scoped var paint = new PaintStore();
    var bytes = new LayoutTransaction(paint).encodeInto(new LayoutNode(1, LayoutVisualKind.Image, style));
    var record = NativeKitUIConstants.NKUI_LAYOUT_TRANSACTION_HEADER_BYTES;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET) != 3
        || bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET) != 2
        || bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET) != 1) return 6;
    return 42;
}
