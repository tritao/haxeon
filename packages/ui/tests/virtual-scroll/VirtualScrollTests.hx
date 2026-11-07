import haxeon.platform.Runtime;
import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.collections.VirtualGrid;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.text.Text;

private class Items implements TreeViewModel {
  public function new() {}
  public function rootCount():Int return 10000;
  public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
    return [for (i in start...start + count) new TreeRootMetadata("item-" + i, false)];
  public function childCount(key:String):Int return 0;
  public function childKeyAt(key:String, index:Int):String return "";
  public function initiallyExpanded(key:String):Bool return false;
  public function estimatedExtent():Float return 24;
  public function extentIsUniform():Bool return true;
  public function extentAt(key:String):Float return 24;
  public function revision():Int return 1;
  public function buildItem(key:String):View return new Text(key);
}

class VirtualScrollTests {
  static function check(value:Bool, message:String):Void if (!value) throw message;
  static function exercise(fonts:FontCollection, name:String, view:View, controller:ScrollController,
      first:Void->Int, last:Void->Int, resize:Void->Void):Void {
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var builds = 0;
    var retained = new RetainedView("pane", _ -> { builds++; return view; });
    var frame = new LayoutFrame(240, 240);
    var submit = () -> ui.submitCached(() -> retained, frame, name);
    var root = submit();
    function covered():Void {
      var top = Std.int(Math.floor(controller.offsetY / 24));
      var bottom = Std.int(Math.ceil((controller.offsetY + controller.viewportHeight) / 24));
      check(first() <= top && last() >= bottom,
        name + " left a blank visible range: offset=" + controller.offsetY + " rows=" + first() + ".." + last());
      check(last() - first() < 40, name + " materialized the entire collection");
      var rowIndex = top + 1;
      var columnIndex = Std.int(Math.floor(controller.offsetX / 120)) + 1;
      var expected = name == "grid" ? rowIndex + ":" + columnIndex : "item-" + rowIndex;
      var painted = false;
      root.walk(node -> {
        if (node.layout.text == expected && node.resolved != null) {
          var bounds = node.resolved.clippedViewportBounds();
          if (bounds.width > 0 && bounds.height > 0) painted = true;
        }
      });
      check(painted, name + " did not expose the expected on-screen row content: " + expected);
    }
    covered();
    controller.jumpTo(0, 2400);
    root = submit();
    Sys.println(name + " after jump: offset=" + controller.offsetY + " rows=" + first() + ".." + last() + " builds=" + builds);
    covered();
    ui.scroll(80, 80, 0, 720);
    root = submit();
    covered();
    controller.configureAnimation(true);
    controller.scrollBy(0, 960);
    frame.deltaSeconds = 1 / 60;
    for (_ in 0...15) { root = submit(); covered(); }
    controller.jumpTo(0, 0);
    root = submit();
    covered();
    check(first() == 0, name + " did not restore its first rows without a click");
    resize();
    frame.height = 480;
    root = submit();
    covered();
    frame.height = 240;
    root = submit();
    covered();
    if (name == "grid") {
      controller.jumpTo(480, 2400);
      root = submit();
      covered();
      var found = false;
      root.walk(node -> { if (node.layout.text == "100:4") found = true; });
      check(found, "horizontal grid scrolling kept the old column window");
    }
    ui.dispose();
  }
  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create(); fonts.addSystemFallbacks();
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(240); style.height = LayoutAxis.fixed(240);
    var tree = new TreeView("tree", new Items(), style);
    exercise(fonts, "tree", tree, tree.controller, () -> tree.materializedFirst, () -> tree.materializedLast, () -> { tree.viewportStyle.height = LayoutAxis.grow(); });
    var list = new VirtualList("list", 10000, 24, i -> new Text("item-" + i), style);
    exercise(fonts, "list", list, list.controller, () -> list.materializedFirst, () -> list.materializedLast, () -> { list.viewportStyle.height = LayoutAxis.grow(); });
    var grid = new VirtualGrid("grid", 10000, 10, 24, 120, (r,c) -> new Text(r + ":" + c), style);
    exercise(fonts, "grid", grid, grid.controller, () -> grid.materializedFirst, () -> grid.materializedLast, () -> { grid.viewportStyle.height = LayoutAxis.grow(); });
    // Fully materialized content continues scrolling by moving its retained nodes.
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var plain = new ScrollView("plain", new Spacer("document", LayoutAxis.fixed(200), LayoutAxis.fixed(10000)), style);
    var builds = 0;
    var retained = new RetainedView("plain-pane", _ -> { builds++; return plain; });
    var frame = new LayoutFrame(240, 240);
    ui.submitCached(() -> retained, frame, "plain");
    plain.controller.jumpTo(0, 2400);
    ui.submitCached(() -> retained, frame, "plain");
    check(builds == 1, "ordinary scrolling rebuilt fully materialized content");
    check(plain.controller.offsetY == 2400, "ordinary scroll fixture did not actually move");
    ui.dispose();
    // Shrinking data clamps the offset during layout; the same frame must rebuild the visible window.
    var shrinkingUi = new UiContext(null, fonts);
    shrinkingUi.buildContext.environment.reducedMotion = true;
    var count = new Signal(10000);
    var controller = new ScrollController();
    var current:Null<VirtualList> = null;
    var shrinking = new RetainedView("shrinking-pane", _ -> {
      var list = new VirtualList("shrinking", count.value, 24, i -> new Text("item-" + i), style, null, controller);
      current = list;
      return list;
    });
    shrinkingUi.submitCached(() -> shrinking, frame, "shrinking");
    controller.jumpTo(0, 2400);
    shrinkingUi.submitCached(() -> shrinking, frame, "shrinking");
    count.value = 5;
    shrinkingUi.submitCached(() -> shrinking, frame, "shrinking");
    var clamped = current;
    if (clamped == null) throw "missing clamped collection";
    check(controller.offsetY == 0 && clamped.materializedFirst == 0 && clamped.materializedLast == 5,
      "data shrink painted stale rows after clamping the offset");
    shrinkingUi.dispose(); fonts.dispose(); runtime.dispose();
    Sys.println("PASS: cached virtual trees, lists and grids refresh on jump, wheel and animated scroll; ordinary scrolling retains content");
    return 0;
  }
}
