import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutWrapMode;
import haxeon.ui.LayoutSelfAlignment;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutTransaction;
import haxeon.ui.style.StyleValue;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.ComputedStyle;

function main():Int {
    var declarations = [StyleValue.direction(LayoutDirection.LeftToRight),
        StyleValue.alignX(LayoutAlignmentX.End), StyleValue.alignY(LayoutAlignmentY.Baseline),
        StyleValue.distribution(LayoutDistribution.SpaceAround), StyleValue.positioning(LayoutPositioning.Absolute),
        StyleValue.wrapMode(LayoutWrapMode.Wrap), StyleValue.alignSelf(LayoutSelfAlignment.Center)];
    var same = [StyleValue.direction(LayoutDirection.LeftToRight),
        StyleValue.alignX(LayoutAlignmentX.End), StyleValue.alignY(LayoutAlignmentY.Baseline),
        StyleValue.distribution(LayoutDistribution.SpaceAround), StyleValue.positioning(LayoutPositioning.Absolute),
        StyleValue.wrapMode(LayoutWrapMode.Wrap), StyleValue.alignSelf(LayoutSelfAlignment.Center)];
    var other = [StyleValue.direction(LayoutDirection.TopToBottom),
        StyleValue.alignX(LayoutAlignmentX.Start), StyleValue.alignY(LayoutAlignmentY.Start),
        StyleValue.distribution(LayoutDistribution.Start), StyleValue.positioning(LayoutPositioning.Flow),
        StyleValue.wrapMode(LayoutWrapMode.NoWrap), StyleValue.alignSelf(LayoutSelfAlignment.Inherit)];
    var computed = new ComputedStyle();
    for (index in 0...declarations.length) {
        if (!declarations[index].sameAs(same[index]) || declarations[index].sameAs(other[index])
            || declarations[index].key() != same[index].key()) return 1;
        declarations[index].applyTo(computed, null);
    }
    computed.setInteger(StyleProperty.ZIndex, 7, null);
    var style = computed.toLayoutStyle(), copy = computed.copy().toLayoutStyle();
    if (haxeon.Diff.mask(style, copy) != 0 || style.zIndex != 7
        || style.direction != LayoutDirection.LeftToRight || style.childAlignX != LayoutAlignmentX.End
        || style.childAlignY != LayoutAlignmentY.Baseline || style.childDistribution != LayoutDistribution.SpaceAround
        || style.positioning != LayoutPositioning.Absolute || style.wrapMode != LayoutWrapMode.Wrap
        || style.alignSelf != LayoutSelfAlignment.Center) return 2;
    var escaped:Dynamic = declarations[0].inspect();
    var checked:LayoutDirection = cast escaped;
    if (checked != LayoutDirection.LeftToRight) return 3;
    var directions = [LayoutDirection.LeftToRight, LayoutDirection.TopToBottom];
    if (Type.enumIndex(directions[1]) != 1) return 4;
    var bytes = LayoutTransaction.encode(new LayoutNode(1, LayoutVisualKind.Box, style));
    var record = NativeKitUIConstants.NKUI_LAYOUT_TRANSACTION_HEADER_BYTES;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_DIRECTION_OFFSET) != 0
        || bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_CHILD_ALIGNMENT_OFFSET) != 769
        || (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_FLAGS_OFFSET) & 2) == 0) return 5;
    var invalid = new LayoutStyle(); invalid.width = LayoutAxis.fixed(-1);
    var rejected = false;
    try LayoutTransaction.encode(new LayoutNode(2, LayoutVisualKind.Box, invalid)) catch (_:Dynamic) rejected = true;
    return rejected ? 42 : 6;
}
