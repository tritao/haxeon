import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.SizedBox;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

private class Files implements TreeViewModel {
  public function new() {}
  public function rootCount():Int return 10000;
  public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
    return [for (i in start...(start + count)) new TreeRootMetadata("file-" + i, false)];
  public function rootKeyAt(index:Int):String return "file-" + index;
  public function childCount(key:String):Int return 0;
  public function childKeyAt(key:String, index:Int):String return "";
  public function initiallyExpanded(key:String):Bool return false;
  public function estimatedExtent():Float return 24.0;
  public function extentIsUniform():Bool return true;
  public function extentAt(key:String):Float return 24.0;
  public function revision():Int return 1;
  public function buildItem(key:String):View return new Row("file", [
    new KeyedView("label", new SizedBox("label", new haxeon.ui.widgets.text.MiddleEllipsisText("filename", key + ".hx", false)))
  ]);
}

@:access(haxeon.ui.core.RenderNode)
class TreeHoverTests {
  static function hoverUpdates(ui:UiContext):Int {
    var metrics:haxeon.ui.debug.UiFrameMetrics = cast ui.frameMetrics;
    return metrics.hoverPaintUpdatedNodes;
  }
  static function commands(node:RenderNode):Int {
    var canvas = new haxeon.ui.Canvas();
    node.paintContent(canvas);
    var list = haxeon.ui.DisplayList.create();
    canvas.update(list);
    var count = list.info().commandCount;
    list.dispose();
    return count;
  }
  static function check(value:Bool, message:String):Void if (!value) throw message;
  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(320.0); style.height = LayoutAxis.fixed(320.0);
    var tree = new TreeView("files", new Files(), style);
    var frame = new LayoutFrame(320.0, 320.0);
    var builds = 0;
    var build = function():View { builds++; return tree; };
    var root = ui.submitCached(build, frame, "files");
    var rows:Array<RenderNode> = [];
    root.walk(function(node) {
      if (node.semantics != null && node.semantics.role == AccessibilityRole.TreeItem && node.resolved != null
          && node.globalBounds().y >= 0 && node.globalBounds().y < 240) rows.push(node);
    });
    check(rows.length >= 8, "Not enough visible rows");
    for (row in rows) check(row.globalBounds().width > 0, "Tree row lost intrinsic width");
    var first = rows[0].globalBounds();
    ui.pointerMove(120, first.y + 8);
    for (_ in 0...12) { frame.deltaSeconds = 0.1; root = ui.submitCached(build, frame, "files"); }
    var beforeBuilds = builds;
    var samples:Array<Float> = [];
    for (i in 0...120) {
      var bounds = rows[i % 8].globalBounds();
      var start = Sys.time();
      ui.pointerMove(120, bounds.y + 8);
      root = ui.submitCached(build, frame, "files");
      samples.push((Sys.time() - start) * 1000);
    }
    samples.sort(function(a,b) return a < b ? -1 : a > b ? 1 : 0);
    Sys.println("HOVER submit: builds=" + (builds - beforeBuilds) + " p50_ms=" + samples[60] + " p95_ms=" + samples[114]);
    if (Sys.args().indexOf("--baseline") < 0) {
      check(builds == beforeBuilds, "Crossing file rows rebuilt the view tree");
      var metrics = ui.frameMetrics;
      check(metrics != null && metrics.reusedSubmission && !metrics.nativeLayoutSubmitted, "Hover submitted native layout");
      check(commands(rows[7]) > 0 && commands(rows[6]) == 0, "Retained background did not follow hover");
      var geometry = rows[7].resolved;
      var count = builds;
      for (i in 0...200) ui.pointerMove(120, rows[i % 8].globalBounds().y + 8);
      root = ui.submitCached(build, frame, "files");
      check(builds == count && rows[7].resolved == geometry, "Batched hover changed geometry or rebuilt");
      check(hoverUpdates(ui) <= 2, "Obsolete pointer positions were repainted");
      ui.pointerMove(120, rows[2].globalBounds().y + 8);
      root = ui.submitCached(build, frame, "files");
      check(hoverUpdates(ui) == 2 && commands(rows[2]) > 0 && commands(rows[7]) == 0,
        "Cross-row hover did not invalidate just the previous and next rows");
      ui.pointerMove(-20, -20);
      root = ui.submitCached(build, frame, "files");
      var rebuiltRows:Array<RenderNode> = [];
      root.walk(function(node) { if (node.semantics != null && node.semantics.role == AccessibilityRole.TreeItem) rebuiltRows.push(node); });
      check(commands(rebuiltRows[2]) == 0, "Leaving the tree left a stale highlight");
      // Theme hover rules can change text metrics; they must use the ordinary build path.
      ui.buildContext.styleSheet.rule(haxeon.ui.style.StyleSelector.widget("text").state(haxeon.ui.style.StyleState.Hovered),
        [haxeon.ui.style.StyleValue.of(haxeon.ui.style.StyleProperty.FontSize, 22.0)]);
      root = ui.submitCached(build, frame, "files");
      ui.pointerMove(35, 8);
      root = ui.submitCached(build, frame, "files");
      count = builds;
      ui.pointerMove(35, 32);
      root = ui.submitCached(build, frame, "files");
      check(builds > count, "Hover stylesheet bypassed the ordinary build path");
      // Focus, selection, model changes and viewport changes must not use hover-only reuse.
      count = builds;
      check(tree.select("file-3"), "Selection did not change");
      root = ui.submitCached(build, frame, "files");
      check(builds > count, "Selection bypassed rebuilding");
      count = builds; frame.width = 300;
      ui.submitCached(build, frame, "files");
      check(builds > count, "Resize bypassed rebuilding");
      var clicks = 0;
      var button = new haxeon.ui.widgets.controls.Button("Action", null, function() clicks++, "action");
      var buttonBuilds = 0;
      var buildButton = function():View { buttonBuilds++; return button; };
      var buttonRoot = ui.submitCached(buildButton, frame, "button");
      var rect = buttonRoot.globalBounds();
      ui.pointerMove(rect.x + rect.width / 2, rect.y + rect.height / 2);
      ui.submitCached(buildButton, frame, "button");
      check(buttonBuilds > 1, "Unregistered widget hover bypassed rebuilding");
      ui.pointerDown(rect.x + rect.width / 2, rect.y + rect.height / 2, 0);
      ui.submitCached(buildButton, frame, "button");
      ui.pointerUp(rect.x + rect.width / 2, rect.y + rect.height / 2, 0);
      check(clicks == 1, "Hover reuse changed button activation");
      Sys.println("PASS: retained backgrounds, batched pointer moves, leave, stylesheet/selection/resize fallbacks and button activation");
    }
    ui.dispose(); fonts.dispose(); runtime.dispose();
    return 0;
  }
}
