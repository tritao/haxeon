import haxeon.ui.FontFamily;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextWrap;
import haxeon.ui.TextDirection;
import haxeon.ui.TextStyle;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutTransaction;
function main():Int {
    var fonts = [FontFamily.Default, FontFamily.Emoji, FontFamily.Monospace];
    var fontCodes = [0, 1, 4];
    for (i in 0...fonts.length)
        if (Type.enumIndex(fonts[i]) != i || haxeon.ui.NativeEnums.fontFamily(fonts[i]).rawValue() != fontCodes[i]) return 1;
    var alignments = [TextAlignment.Start, TextAlignment.Center, TextAlignment.End];
    for (i in 0...alignments.length)
        if (haxeon.ui.NativeEnums.textAlignment(alignments[i]).rawValue() != i) return 2;
    var wraps = [TextWrap.None, TextWrap.Word, TextWrap.WordCharacter];
    for (i in 0...wraps.length)
        if (haxeon.ui.NativeEnums.textWrap(wraps[i]).rawValue() != i) return 3;
    var directions = [TextDirection.Auto, TextDirection.Ltr, TextDirection.Rtl];
    for (i in 0...directions.length) {
        var native = haxeon.ui.NativeEnums.textDirection(directions[i]);
        if (native.rawValue() != i || haxeon.ui.NativeEnums.textDirectionFromNative(native) != directions[i]) return 3;
    }
    var node = new LayoutNode(1);
    node.textStyle = new TextStyle(16, FontFamily.Monospace);
    node.paragraphStyle = new ParagraphStyle(TextWrap.WordCharacter, TextAlignment.Center, null, TextDirection.Rtl);
    var bytes = LayoutTransaction.encode(node);
    var record = NativeKitUIConstants.NKUI_LAYOUT_TRANSACTION_HEADER_BYTES;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_FONT_FAMILY_OFFSET) != 4) return 4;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_WRAP_OFFSET) != 2) return 4;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_ALIGNMENT_OFFSET) != 1) return 4;
    if (bytes.getInt32(record + NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_DIRECTION_OFFSET) != 2) return 4;
    return 42;
}
