import haxeon.editor.TextDocument;
import haxeon.ui.FontCollection;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.widgets.text.TextEditorLayout;

class EditorResizeTests {
  static function near(a:Float, b:Float):Bool return Math.abs(a - b) < 0.01;

  static function verify(fonts:FontCollection, document:TextDocument, layout:TextEditorLayout):Void {
    var fresh = new TextEditorLayout(fonts, document.text, layout.width,
      layout.textStyle, layout.paragraphStyle, document);
    var a = layout.measure(), b = fresh.measure();
    if (!near(a.width, b.width) || !near(a.height, b.height)) throw "Resize metrics differ from fresh layout";
    for (offset in [0, 5, Std.int(document.codepointCount / 2), document.codepointCount]) {
      var actual = layout.caret(new TextPosition(offset, 0));
      var expected = fresh.caret(new TextPosition(offset, 0));
      if (!near(actual.x, expected.x) || !near(actual.y, expected.y)) throw "Resize caret geometry differs from fresh layout";
    }
    var start = new TextPosition(0, 0), end = new TextPosition(document.codepointCount, 0);
    var actual = layout.selectionRects(start, end, 0, 200), expected = fresh.selectionRects(start, end, 0, 200);
    if (actual.length != expected.length) throw "Resize selection rectangle count changed";
    for (index in 0...actual.length) {
      var x = actual[index], y = expected[index];
      if (!near(x.x, y.x) || !near(x.y, y.y) || !near(x.width, y.width) || !near(x.height, y.height))
        throw "Resize selection geometry differs from fresh layout";
    }
    fresh.dispose();
  }

  static function main():Int {
    var fonts = FontCollection.create();
    fonts.add(Sys.getEnv("NKUI_TEST_FONT_PATH"));
    for (wrap in [TextWrap.None, TextWrap.WordCharacter]) for (alignment in [TextAlignment.Start, TextAlignment.Center]) {
      var document = new TextDocument([for (i in 0...150) i + " Latin café אבג é long source line"].join("\n"));
      var style = new TextStyle(16), paragraph = new ParagraphStyle(wrap, alignment);
      var layout = new TextEditorLayout(fonts, document.text, 160, style, paragraph, document);
      for (width in [300.0, 75.0, 240.0]) {
        var rowsRevision = layout.visualRowsRevision;
        layout.updateDocument(document, width, style, paragraph);
        if (wrap == TextWrap.None && layout.visualRowsRevision != rowsRevision)
          throw "Unwrapped viewport resize invalidated visual rows";
        if (wrap != TextWrap.None && layout.visualRowsRevision <= rowsRevision)
          throw "Wrapped viewport resize did not invalidate visual rows";
        verify(fonts, document, layout);
      }
      var oldLength = document.codepointCount;
      var rowsBeforeEdit = layout.visualRowsRevision;
      document.replace(0, 3, "prefix\n");
      layout.setTextAfterEdit(document, 0, 3, 0, 7, oldLength);
      if (layout.visualRowsRevision <= rowsBeforeEdit) throw "Edit did not invalidate visual rows";
      layout.updateDocument(document, 120, style, paragraph);
      verify(fonts, document, layout);
      document.replace(0, 2, "changed");
      layout.updateDocument(document, 200, style, paragraph);
      verify(fonts, document, layout);
      var revision = layout.geometryRevision;
      layout.updateDocument(document, 200, style, paragraph);
      if (layout.geometryRevision != revision) throw "Unchanged layout was recomputed";
      layout.dispose();
    }
    fonts.dispose();
    Sys.println("PASS: resize geometry, wrapped/bidi text and edits match fresh layouts");
    return 0;
  }
}
