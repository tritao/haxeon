package haxeon.ui.core;

import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.style.StyleDiff;

/** A text leaf owns its previous submitted value without a render-tree snapshot. */
@:access(haxeon.ui.core.RenderNode)
class LiveTextNode extends RenderNode {
  var submittedText:String;
  var announcedText:String;

  public function new(id:WidgetId, style:LayoutStyle, value:String) {
    super(id, LayoutVisualKind.Text, style);
    submittedText = value;
    announcedText = value;
  }

  public function setText(value:String):Void {
    announcedText = value;
    layout.text = value;
    if (semantics != null) semantics.label = value;
  }

  override public function submittedFingerprint():Int {
    if (layout.text != announcedText || semantics != null && semantics.label != announcedText) return fingerprint();
    return fingerprintText(submittedText, semantics == null ? null : submittedText);
  }

  override function syncRevisions(previous:Null<RenderNode>, diff:StyleDiff, accumulate:Bool = false):Void {
    var beforeText = previous == null ? layout.text : Std.isOfType(previous, LiveTextNode)
      ? (cast previous:LiveTextNode).submittedText : previous.layout.text;
    var beforeContent = previous == null ? contentRevision : previous.contentRevision;
    var beforePaint = previous == null ? paintRevision : previous.paintRevision;
    var beforeGeometry = previous == null ? geometryRevision : previous.geometryRevision;
    super.syncRevisions(previous, diff, accumulate);
    if (beforeText != layout.text) {
      if (contentRevision == beforeContent) contentRevision++;
      if (paintRevision == beforePaint) paintRevision++;
      if (geometryRevision == beforeGeometry) geometryRevision++;
      paintKeyResolved = false;
      invalidationFlags |= UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout |
        UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsSemantics;
    }
    submittedText = layout.text;
  }
}
