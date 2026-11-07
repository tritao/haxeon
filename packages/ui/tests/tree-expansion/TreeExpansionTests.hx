import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.text.Text;

private class Items implements TreeViewModel {
  public var defaultOpen:Bool = true;
  public function new() {}
  public function rootCount():Int return 1;
  public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> return [new TreeRootMetadata("root", true)];
  public function childCount(key:String):Int return key == "root" ? 2 : key == "group" ? 2 : 0;
  public function childKeyAt(key:String, index:Int):String return key == "root" ? ["group", "other"][index] : ["a", "b"][index];
  public function initiallyExpanded(key:String):Bool return key == "root" && defaultOpen;
  public function estimatedExtent():Float return 24;
  public function extentIsUniform():Bool return true;
  public function extentAt(key:String):Float return 24;
  public function buildItem(key:String):haxeon.ui.core.View return new Text(key);
}

class TreeExpansionTests {
  static function check(value:Bool, message:String):Void if (!value) throw message;
  static function hasText(root:RenderNode, value:String):Bool {
    var found = false;
    root.walk(node -> { if (node.layout.text == value) found = true; });
    return found;
  }
  static function disclosure(root:RenderNode, rowKey:String):RenderNode {
    var found:Null<RenderNode> = null;
    root.walk(row -> {
      if (row.semantics != null && row.semantics.role == AccessibilityRole.TreeItem && row.semantics.label == rowKey)
        row.walk(node -> { if (node.semantics != null && node.semantics.role == AccessibilityRole.Button) found = node; });
    });
    if (found == null) throw "Missing disclosure for " + rowKey;
    return found;
  }
  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create(); fonts.addSystemFallbacks();
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var style = new LayoutStyle(); style.width = LayoutAxis.fixed(320); style.height = LayoutAxis.fixed(240);
    var model = new Items();
    var tree = new TreeView("tree", model, style);
    var pane = new RetainedView("pane", _ -> tree);
    var frame = new LayoutFrame(320, 240);
    var submit = () -> ui.submitCached(() -> pane, frame, "tree");
    var root = submit();
    check(hasText(root, "group") && !hasText(root, "a"), "initial tree fixture is incorrect");
    var started = Sys.time();
    check(tree.setExpanded("group", true), "group did not expand logically");
    root = submit();
    Sys.println('EXPAND: milliseconds=${(Sys.time()-started)*1000} childrenPainted=${hasText(root,"a")}');
    check(hasText(root, "a"), "expansion reused stale rows until an unrelated input");
    // Keep focus on the same arrow so focus changes cannot hide missing state invalidation.
    for (_ in 0...4) {
      var arrow = disclosure(root, "group");
      var bounds = arrow.globalBounds();
      ui.pointerDown(bounds.x + 8, bounds.y + 8, 0); ui.pointerUp(bounds.x + 8, bounds.y + 8, 0);
      root = submit();
      check(!hasText(root, "a") && !tree.isExpanded("group"), "focused arrow collapse did not update immediately");
      arrow = disclosure(root, "group");
      bounds = arrow.globalBounds();
      ui.pointerDown(bounds.x + 8, bounds.y + 8, 0); ui.pointerUp(bounds.x + 8, bounds.y + 8, 0);
      root = submit();
      check(hasText(root, "a") && tree.isExpanded("group"), "focused arrow expansion did not update immediately");
    }
    check(tree.collapseAll(true), "collapse-all did not change the tree");
    root = submit();
    check(hasText(root, "group") && !hasText(root, "a"), "collapse-all keeping roots reused stale rows");
    check(tree.collapseAll(), "full collapse-all did not change the tree");
    root = submit();
    check(!hasText(root, "group"), "full collapse-all reused stale rows");
    tree.setExpanded("root", true);
    root = submit();
    var arrow = disclosure(root, "group");
    ui.focusWidget(arrow.id);
    ui.key(UiEventKind.KeyDown, UiKey.Enter); ui.key(UiEventKind.KeyUp, UiKey.Enter);
    root = submit();
    check(hasText(root, "a"), "keyboard disclosure activation did not refresh the tree");
    // A fresh view instance must hydrate the expansion state stored under the same tree key.
    ui.pointerLeave(); ui.clearFocus();
    model.defaultOpen = false;
    tree = new TreeView("tree", model, style);
    root = ui.submit(pane, frame);
    check(hasText(root, "a"), "fresh tree view lost its saved expansion state");
    ui.dispose(); fonts.dispose(); runtime.dispose();
    Sys.println("PASS: cached expansion, focused disclosure clicks, keyboard activation, collapse-all and state hydration");
    return 0;
  }
}
