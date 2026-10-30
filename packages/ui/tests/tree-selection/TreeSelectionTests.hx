import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.core.RetainedView;

private class Items implements TreeViewModel {
  public function new() {}
  public function rootCount():Int return 12;
  public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
    return [for (i in start...(start + count)) new TreeRootMetadata("item-" + i, false)];
  public function rootKeyAt(index:Int):String return "item-" + index;
  public function childCount(key:String):Int return 0;
  public function childKeyAt(key:String, index:Int):String return "";
  public function initiallyExpanded(key:String):Bool return false;
  public function estimatedExtent():Float return 24.0;
  public function extentIsUniform():Bool return true;
  public function extentAt(key:String):Float return 24.0;
  public function revision():Int return 1;
  public function buildItem(key:String):View return new Text(key);
}

/** Shift and Control clicks build a multi-selection only when the tree opts in. */
class TreeSelectionTests {
  static function check(value:Bool, message:String):Void if (!value) throw message;

  static function rowY(root:RenderNode, key:String):Float {
    var y = -1.0;
    root.walk(function(node) {
      if (node.semantics != null && node.semantics.role == AccessibilityRole.TreeItem && node.semantics.label == key)
        y = node.globalBounds().y + 12;
    });
    if (y < 0) throw 'Row $key is not visible';
    return y;
  }

  static function selectedRows(root:RenderNode):String {
    var keys:Array<String> = [];
    root.walk(function(node) {
      if (node.semantics != null && node.semantics.role == AccessibilityRole.TreeItem
          && (node.semantics.states & AccessibilityState.Selected) != 0) keys.push(node.semantics.label);
    });
    return keys.join(",");
  }

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(240.0); style.height = LayoutAxis.fixed(320.0);
    var tree = new TreeView("items", new Items(), style);
    tree.multiSelect = true;
    var opened:Array<String> = [];
    var menus:Array<String> = [];
    tree.onItemClicked = function(key, _) opened.push(key);
    tree.onItemContextMenu = function(key, _) menus.push(key);
    var frame = new LayoutFrame(240.0, 320.0);
    var build = function():View return tree;
    var root = ui.submit(build(), frame);
    function click(key:String, modifiers:Int = 0, button:Int = 0):Void {
      var y = rowY(root, key);
      ui.pointerDown(60, y, button, modifiers);
      ui.pointerUp(60, y, button, modifiers);
      root = ui.submit(build(), frame);
    }
    function selection():String return tree.selectedKeys().join(",");

    click("item-2");
    check(selection() == "item-2" && opened.join(",") == "item-2", "Plain click did not select and report one row");
    click("item-5", UiModifier.Shift);
    check(selection() == "item-2,item-3,item-4,item-5", "Shift-click did not select the range: " + selection());
    check(tree.selectedKey == "item-5" && opened.length == 1, "Shift-click moved focus wrongly or reported a plain click");
    check(selectedRows(root) == "item-2,item-3,item-4,item-5", "Rows did not paint the range: " + selectedRows(root));
    click("item-3", UiModifier.Control);
    check(selection() == "item-2,item-4,item-5", "Control-click did not remove a row: " + selection());
    click("item-8", UiModifier.Control);
    check(selection() == "item-2,item-4,item-5,item-8", "Control-click did not add a row: " + selection());
    click("item-10", UiModifier.Shift);
    check(selection() == "item-8,item-9,item-10", "Shift-click after Control-click did not range from the toggled row: " + selection());
    var y = rowY(root, "item-9");
    ui.pointerDown(60, y, 1);
    ui.pointerUp(60, y, 1);
    root = ui.submit(build(), frame);
    check(menus.join(",") == "item-9" && selection() == "item-8,item-9,item-10", "A menu on a selected row changed the selection");
    y = rowY(root, "item-0");
    ui.pointerDown(60, y, 1);
    ui.pointerUp(60, y, 1);
    root = ui.submit(build(), frame);
    check(selection() == "item-0", "A menu on an unselected row kept the old selection: " + selection());
    click("item-4", UiModifier.Shift);
    click("item-1");
    check(selection() == "item-1" && opened.join(",") == "item-2,item-1", "Plain click did not collapse the selection: " + selection());

    // Trees that do not opt in keep single selection for modified clicks.
    tree.multiSelect = false;
    click("item-6", UiModifier.Shift);
    check(selection() == "item-6" && opened.join(",") == "item-2,item-1,item-6", "Single-select tree handled Shift-click as a range");
    click("item-7", UiModifier.Control);
    check(selection() == "item-7", "Single-select tree handled Control-click as a toggle");
    var controlled = new UiContext(null, fonts);
    controlled.buildContext.environment.reducedMotion = true;
    var choice:Null<String> = null, notifications = 0;
    var controlledBuild = function():View return new RetainedView("controlled-tree", function(_) {
      var next = new TreeView("controlled-items", new Items(), style);
      next.selectionProvider = function() return choice;
      next.onSelectionChanged = function(key) { choice = key; notifications++; };
      return next;
    });
    // Build the parent each frame; RetainedView itself must observe and invalidate its cached tree.
    for (desired in ["item-1", "item-8", null, "missing", "item-2"]) {
      choice = desired;
      var mounted = controlled.submit(controlledBuild(), frame);
      var expected = desired == null || desired == "missing" ? "" : desired;
      check(selectedRows(mounted) == expected, "Controlled selection did not follow its owner: expected " + expected + " actual " + selectedRows(mounted));
      check(notifications == 0, "Synchronizing a controlled selection notified its owner");
      check(controlled.verifyRetention(controlledBuild, frame) == null, "Controlled selection differs from a fresh tree");
    }
    var mounted = controlled.root;
    if (mounted == null) throw "Controlled tree was not mounted";
    var controlledY = rowY(mounted, "item-4");
    controlled.pointerDown(60, controlledY, 0);
    controlled.pointerUp(60, controlledY, 0);
    mounted = controlled.submit(controlledBuild(), frame);
    check(choice == "item-4" && notifications == 1 && selectedRows(mounted) == "item-4", "Controlled input did not update its owner");
    check(controlled.verifyRetention(controlledBuild, frame) == null, "Controlled input differs from a fresh tree");
    controlled.dispose();
    Sys.println("PASS: observed controlled selection, clearing, absent keys and input match fresh builds");
    Sys.println("PASS: range, toggle, anchor, menu and single-select clicks");
    ui.dispose(); fonts.dispose(); runtime.dispose();
    return 0;
  }
}
