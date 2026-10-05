package nativekit.ui.widgets.text;

import FontFamily;
import nativekit.editorkit.TextDocument;
import LayoutAxis;
import LayoutStyle;
import ParagraphStyle;
import TextAlignment;
import TextDirection;
import TextLayout;
import TextStyle;
import TextWrap;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.core.View;
import nativekit.ui.theme.TextRole;

/** Fits a single-line label with an ellipsis, preserving both ends by default or only the prefix. */
class MiddleEllipsisText implements View {
  public final key:String;
  public final value:String;
  public final middle:Bool;
  public final textStyle:Null<TextStyleOverride>;
  public var truncated(default, null):Bool = false;

  public function new(key:String, value:String, middle:Bool = true, ?textStyle:TextStyleOverride) {
    this.key = key;
    this.value = value;
    this.middle = middle;
    this.textStyle = textStyle;
  }

  public function build(context:BuildContext):RenderNode {
    return context.withScope(new Key(key), function() {
      var displayed = context.resourceState(context.id("displayed"), function() return value, function(_) {});
      var style = new LayoutStyle();
      style.width = LayoutAxis.grow();
      style.clipHorizontal = true;
      var text = new Text(displayed.value, style, null,
        textStyle == null ? TextStyleOverride.paragraph(TextWrap.None) : textStyle);
      var node = text.build(context);
      if (node.semantics != null) node.semantics.label = value;
      var resolved = context.resolveTextRole(TextRole.Body, textStyle);
      // Shaping a layout to measure is the expensive part, so remember the answer while its inputs stay the same.
      var memo:EllipsisMemo = context.resourceState(context.id("ellipsis-memo"), function() return new EllipsisMemo(), function(_) {}).value;
      node.onResolved(function(geometry) {
        if (context.fonts == null) return;
        var available = Math.max(0.0, geometry.clippedViewportBounds().width);
        var next:String;
        if (memo.matches(value, available, resolved.textStyle, resolved.paragraphStyle))
          next = memo.result;
        else {
          var paragraph = new ParagraphStyle(TextWrap.None, resolved.paragraphStyle.alignment,
            resolved.paragraphStyle.lineHeight, resolved.paragraphStyle.direction);
          var layout = TextLayout.createStyled(context.fonts, value, 100000.0,
            resolved.textStyle, paragraph);
          next = value;
          if (layout.measure().width > available + 1.0) {
            var document = new TextDocument(value);
            var low = 0, high = document.codepointCount;
            while (low < high) {
              var count = (low + high + 1) >> 1;
              var prefix = middle ? (count + 1) >> 1 : count;
              var candidate = document.sliceCodepoints(0, prefix) + "…" + document.sliceCodepoints(document.codepointCount - (count - prefix), document.codepointCount);
              layout.setText(candidate);
              if (layout.measure().width <= available) low = count;
              else high = count - 1;
            }
            var prefix = middle ? (low + 1) >> 1 : low;
            next = document.sliceCodepoints(0, prefix) + "…" + document.sliceCodepoints(document.codepointCount - (low - prefix), document.codepointCount);
          }
          layout.dispose();
          memo.store(value, available, resolved.textStyle, resolved.paragraphStyle, next);
        }
        truncated = next != value;
        if (displayed.value != next) displayed.update(next);
      });
      return node;
    });
  }
}

/** The last truncation and the inputs that decided it; the result only changes when one of them does. */
private class EllipsisMemo {
  var value:Null<String> = null;
  var available:Float = -1.0;
  var font:Null<FontFamily> = null;
  var fontSize:Float = 0.0;
  var letterSpacing:Float = 0.0;
  var alignment:Null<TextAlignment> = null;
  var lineHeight:Null<Float> = null;
  var direction:Null<TextDirection> = null;
  public var result:String = "";

  public function new() {}

  public function matches(value:String, available:Float, text:TextStyle, paragraph:ParagraphStyle):Bool
    return this.value != null && this.value == value && this.available == available && font == text.font &&
      fontSize == text.fontSize && letterSpacing == text.letterSpacing && alignment == paragraph.alignment &&
      lineHeight == paragraph.lineHeight && direction == paragraph.direction;

  public function store(value:String, available:Float, text:TextStyle, paragraph:ParagraphStyle, result:String):Void {
    this.value = value;
    this.available = available;
    font = text.font;
    fontSize = text.fontSize;
    letterSpacing = text.letterSpacing;
    alignment = paragraph.alignment;
    lineHeight = paragraph.lineHeight;
    direction = paragraph.direction;
    this.result = result;
  }
}
