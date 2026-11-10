import haxeon.ui.FontFamily;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextWrap;
import haxeon.ui.TextDirection;
import haxeon.ui.TextStyle;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutTransaction;
function main():Int {
    var valuesFontFamily = [FontFamily.Default, FontFamily.Emoji, FontFamily.Monospace];
    for (value in valuesFontFamily) {
        var decoded = FontFamily.fromRaw(value.rawValue());
        if (decoded == null || decoded != value) return 1;
    }
    if (FontFamily.fromRaw(-1) != null || FontFamily.fromRaw(99) != null) return 2;
    var valuesTextAlignment = [TextAlignment.Start, TextAlignment.Center, TextAlignment.End];
    for (value in valuesTextAlignment) {
        var decoded = TextAlignment.fromRaw(value.rawValue());
        if (decoded == null || decoded != value) return 1;
    }
    if (TextAlignment.fromRaw(-1) != null || TextAlignment.fromRaw(99) != null) return 2;
    var valuesTextWrap = [TextWrap.None, TextWrap.Word, TextWrap.WordCharacter];
    for (value in valuesTextWrap) {
        var decoded = TextWrap.fromRaw(value.rawValue());
        if (decoded == null || decoded != value) return 1;
    }
    if (TextWrap.fromRaw(-1) != null || TextWrap.fromRaw(99) != null) return 2;
    var valuesTextDirection = [TextDirection.Auto, TextDirection.Ltr, TextDirection.Rtl];
    for (value in valuesTextDirection) {
        var decoded = TextDirection.fromRaw(value.rawValue());
        if (decoded == null || decoded != value) return 1;
    }
    if (TextDirection.fromRaw(-1) != null || TextDirection.fromRaw(99) != null) return 2;
    if (FontFamily.fromRaw(2) != null || FontFamily.fromRaw(3) != null) return 3;
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
