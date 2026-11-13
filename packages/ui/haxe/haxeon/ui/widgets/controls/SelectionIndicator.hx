package haxeon.ui.widgets.controls;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.PathBuilder;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconData;
import haxeon.ui.icons.IconName;
import haxeon.ui.style.StyleProperty;

/** Small font-independent affordances shared by selection controls. */
class SelectionIndicator {
  public static function search(key:String, color:Color):View return new SelectionIndicatorView(
    key,
    0,
    color,
    false,
    false
  );

  public static function fieldFrame(key:String):View return new SelectionIndicatorView(
    key,
    1,
    Color.rgba(0, 0, 0, 0),
    false,
    false
  );

  public static function chevron(key:String,
    color:Color, open:Bool, withFrame:Bool = false):View return new SelectionIndicatorView(
      key,
      2,
      color,
      open,
      withFrame
    );

  public static function check(key:String, color:Color):View return new SelectionIndicatorView(
    key,
    3,
    color,
    false,
    false
  );
}

private class SelectionIndicatorView implements View {
  final key:String;
  final kind:Int;
  final color:Color;
  final open:Bool;
  final withFrame:Bool;
  public function new(key:String, kind:Int, color:Color, open:Bool, withFrame:Bool) {
    this.key = key;
    this.kind = kind;
    this.color = color;
    this.open = open;
    this.withFrame = withFrame;
  }
  public function build(context:BuildContext):RenderNode {
    var indicator = overlay(context, key);
    if (kind == 1 || withFrame) paintFrame(context, indicator);
    if (kind == 0) paintSearch(indicator);
    else if (kind == 2) paintChevron(indicator);
    else if (kind == 3) paintCheck(indicator);
    return indicator;
  }

  function paintSearch(indicator:RenderNode):Void {
    var color = this.color;
    indicator.onPaint(function(canvas, geometry) {
      canvas.withState(function(target) {
        target.translate(11.0, geometry.height * 0.5 - 7.0);
        target.scale(14.0 / 24.0, 14.0 / 24.0);
        target.strokeTransient(IconData.build(IconName.Search), color, 2.0, LineCap.Round, LineJoin.Round);
      }
      );
    }, "selection-search");
  }

  function paintFrame(context:BuildContext, indicator:RenderNode):Void {
    if (context.inheritedStyle == null) return;
    var color = context.inheritedStyle.getColor(StyleProperty.BorderColor);
    var width = context.inheritedStyle.getNumber(StyleProperty.BorderWidth);
    if (color.alpha <= 0.0 || width <= 0.0) return;
    indicator.onPaint(function(canvas, geometry) {
      var edge = Math.min(width, Math.min(geometry.width, geometry.height) * 0.5);
      canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, edge), color);
      canvas.fillRectIfPositive(new Rect(0.0, geometry.height - edge, geometry.width, edge), color);
      canvas.fillRectIfPositive(new Rect(0.0, edge, edge, geometry.height - edge * 2.0), color);
      canvas.fillRectIfPositive(new Rect(geometry.width - edge, edge, edge, geometry.height - edge * 2.0), color);
    }, "selection-field-frame");
  }

  function paintChevron(indicator:RenderNode):Void {
    var color = this.color;
    var open = this.open;
    indicator.onPaint(function(canvas, geometry) {
      var centerX = geometry.width - 16.0;
      var centerY = geometry.height * 0.5;
      var path = open ? new PathBuilder().moveTo(centerX - 4.0, centerY + 2.0).lineTo(centerX, centerY - 2.0).lineTo(
        centerX + 4.0,
        centerY + 2.0
      ).build() : new PathBuilder().moveTo(
        centerX - 4.0,
        centerY - 2.0
      ).lineTo(
        centerX,
        centerY + 2.0
      ).lineTo(
        centerX + 4.0,
        centerY - 2.0
      ).build();
      canvas.strokeTransient(path, color, 1.75, LineCap.Round, LineJoin.Round);
    }, "selection-chevron:" + open);
  }

  function paintCheck(indicator:RenderNode):Void {
    var color = this.color;
    indicator.onPaint(function(canvas, geometry) {
      var centerY = geometry.height * 0.5;
      var path = new PathBuilder().moveTo(10.0,
        centerY).lineTo(13.0, centerY + 3.0).lineTo(18.0, centerY - 3.0).build();
      canvas.strokeTransient(path, color, 1.75, LineCap.Round, LineJoin.Round);
    }, "selection-check");
  }

  static function overlay(context:BuildContext, key:String):RenderNode {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    style.height = LayoutAxis.grow();
    style.positioning = LayoutPositioning.Absolute;
    style.zIndex = 2;
    var result = context.createNode(context.rootId(key), LayoutVisualKind.Custom, style);
    result.hitTestSelf = false;
    return result;
  }
}
