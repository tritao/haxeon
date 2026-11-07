import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.overlays.Tooltip;
import haxeon.ui.widgets.overlays.TooltipPlacement;
import haxeon.ui.widgets.text.Text;

/** A tooltip builds its content only while it is shown, and is still placed inside the viewport when it appears. */
class TooltipContentTests {
  static function check(ok:Bool, message:String):Void {
    if (!ok) throw message;
  }

  static function hints(root:RenderNode):Int {
    var count = 0;
    root.walk(function(node) {
      if (node.layout.text == "Hint") count++;
    });
    return count;
  }

  static function visible(node:RenderNode):Bool {
    var geometry:ResolvedLayoutItem = cast node.resolved;
    return geometry.visible;
  }

  /** Submits frames of `seconds` each until `done` holds or `limit` frames pass; returns the last tree. */
  static function settle(ui:UiContext, view:View, frame:LayoutFrame, seconds:Float, limit:Int, done:RenderNode->Bool):RenderNode {
    var root:RenderNode = null;
    for (_ in 0...limit) {
      frame.deltaSeconds = seconds;
      root = ui.submit(view, frame);
      if (done(root)) break;
    }
    return root;
  }

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    var ui = new UiContext(null, fonts);
    var frame = new LayoutFrame(256.0, 192.0);

    // Inline tooltip: the node exists while hidden, with no content.
    var inlineTip = new Tooltip("inline", new Button("Anchor"), new Text("Hint"));
    var root = ui.submit(inlineTip, frame);
    check(root.children.length == 2, "an inline tooltip is an anchor and a tooltip node");
    check(!visible(root.children[1]), "the inline tooltip starts hidden");
    check(root.children[1].children.length == 0, "a hidden inline tooltip built its content");
    check(hints(root) == 0, "hidden inline content is in the tree");
    var anchor:ResolvedLayoutItem = cast root.children[0].resolved;
    ui.pointerMove(anchor.x + 4.0, anchor.y + 4.0);
    root = ui.submit(inlineTip, frame);
    check(visible(root.children[1]), "hovering the anchor did not show the inline tooltip");
    check(hints(root) == 1, "the shown inline tooltip has no content");
    ui.pointerMove(250.0, 190.0);
    root = ui.submit(inlineTip, frame);
    check(!visible(root.children[1]), "leaving the anchor did not hide the inline tooltip");
    check(hints(root) == 0, "the hidden inline tooltip kept its content");

    // An inline tooltip overlapping the previous row must not trap hover or clicks.
    var clicks = 0;
    var target = new Tooltip("previous", new Button("Previous", null, () -> clicks++), new Text("Previous hint"));
    var source = new Tooltip("overlap", new Button("Next"), new Text("Hint"));
    var pair = new haxeon.ui.widgets.layout.Column("pair", [
      new haxeon.ui.widgets.KeyedView("target", target),
      new haxeon.ui.widgets.KeyedView("source", source)
    ]);
    root = ui.submit(pair, frame);
    var sourceBounds = root.children[1].children[0].globalBounds();
    ui.pointerMove(sourceBounds.x + 4, sourceBounds.y + sourceBounds.height / 2);
    root = ui.submit(pair, frame);
    var overlay = root.children[1].children[1];
    check(visible(overlay), "the overlapping tooltip did not appear");
    var targetBounds = root.children[0].globalBounds();
    var overlayBounds = overlay.globalBounds();
    var px = Math.max(targetBounds.x, overlayBounds.x) + 4;
    var py = Math.max(targetBounds.y, overlayBounds.y) + 4;
    check(px < Math.min(targetBounds.x + targetBounds.width, overlayBounds.x + overlayBounds.width)
      && py < Math.min(targetBounds.y + targetBounds.height, overlayBounds.y + overlayBounds.height),
      "the regression fixture must overlap the neighbouring button");
    var path = haxeon.ui.core.HitTest.path(root, px, py);
    check(path.indexOf(root.children[0]) >= 0 && path.indexOf(overlay) < 0,
      "the tooltip intercepted its neighbour's hit target");
    ui.pointerMove(px, py);
    ui.pointerDown(px, py, 0);
    ui.pointerUp(px, py, 0);
    check(clicks == 1, "the neighbouring button cannot be clicked through the tooltip");
    root = ui.submit(pair, frame);
    check(!visible(root.children[1].children[1]), "the old tooltip stayed visible after moving to its neighbour");
    check(visible(root.children[0].children[1]), "the neighbouring tooltip did not replace the old tooltip");
    ui.clearFocus();
    ui.pointerLeave();

    // Side-placed tooltip: shown after its hover delay, placed inside the viewport.
    for (placement in [TooltipPlacement.Below, TooltipPlacement.Above, TooltipPlacement.Right]) {
      var side = new Tooltip("side-" + Std.string(placement), new Button("Anchor"), new Text("Hint"));
      side.placement = placement;
      side.delaySeconds = 0.5;
      root = ui.submit(side, frame);
      check(hints(root) == 0, "a hidden " + Std.string(placement) + " tooltip built its content");
      anchor = cast root.children[0].resolved;
      ui.pointerMove(anchor.x + 4.0, anchor.y + 4.0);
      check(ui.animations.rebuildingCount == 0 && !ui.animations.needsFrame && ui.animations.waitSeconds() > 0,
        "waiting for a tooltip requested continuous rebuilding frames");
      root = settle(ui, side, frame, 0.2, 2, function(tree) return hints(tree) > 0);
      check(hints(root) == 0, "a " + Std.string(placement) + " tooltip appeared before its hover delay");
      root = settle(ui, side, frame, 0.2, 6, function(tree) return hints(tree) > 0);
      check(hints(root) == 1, "a " + Std.string(placement) + " tooltip never showed its content");
      var tip = root.children[1];
      check(visible(tip), "a " + Std.string(placement) + " tooltip has content but is hidden");
      var bounds = tip.globalBounds();
      check(bounds.width > 0.0 && bounds.height > 0.0, "a " + Std.string(placement) + " tooltip has no size");
      if (placement == TooltipPlacement.Above) {
        // The anchor is at the top of the frame, so a tooltip above it is above the viewport; it must still sit above the anchor.
        check(bounds.y + bounds.height <= root.children[0].globalBounds().y + 0.5, "an Above tooltip is not above its anchor");
      } else {
        check(bounds.x >= -0.5 && bounds.y >= -0.5 && bounds.x + bounds.width <= 256.5 && bounds.y + bounds.height <= 192.5,
          "a " + Std.string(placement) + " tooltip is outside the viewport");
      }
      ui.pointerMove(250.0, 190.0);
      root = settle(ui, side, frame, 0.2, 6, function(tree) return hints(tree) == 0);
      check(hints(root) == 0, "a " + Std.string(placement) + " tooltip kept its content after the pointer left");
      check(ui.focusWidget(root.children[0].id), "the tooltip anchor cannot receive keyboard focus");
      root = ui.submit(side, frame);
      check(hints(root) == 1, "keyboard focus did not show the tooltip");
      ui.clearFocus();
      root = ui.submit(side, frame);
      check(hints(root) == 0, "the tooltip stayed visible after keyboard focus left");
    }
    var suppressed = new Tooltip("suppressed", new Button("Anchor"), new Text("Hint"));
    suppressed.placement = TooltipPlacement.Right;
    suppressed.showWhen = () -> false;
    root = ui.submit(suppressed, frame);
    anchor = cast root.children[0].resolved;
    ui.pointerMove(anchor.x + 4, anchor.y + 4);
    root = settle(ui, suppressed, frame, 0.2, 8, _ -> false);
    check(hints(root) == 0 && ui.animations.activeCount == 0,
      "an ineligible positioned tooltip started a timer or showed content");
    Sys.println("PASS: tooltip content is built only while shown, and shown tooltips are placed");
    fonts.dispose();
    return 0;
  }
}
