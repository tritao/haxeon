import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

private class Items implements TreeViewModel {
  public function new() {}
  public function rootCount():Int return 3;
  public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
    return [for (i in start...(start + count)) new TreeRootMetadata("item-" + i, i == 0)];
  public function rootKeyAt(index:Int):String return "item-" + index;
  public function childCount(key:String):Int return key == "item-0" ? 2 : 0;
  public function childKeyAt(key:String, index:Int):String return key + "-child-" + index;
  public function initiallyExpanded(key:String):Bool return false;
  public function estimatedExtent():Float return 24.0;
  public function extentIsUniform():Bool return true;
  public function extentAt(key:String):Float return 24.0;
  public function revision():Int return 1;
  public function buildItem(key:String):View return new Text(key);
}

/** Application chords must reach the keymap, and Enter on a tree row must be claimable. */
class KeyChordTests {
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

  static function fieldValue(root:RenderNode):String {
    var value:Null<String> = null;
    root.walk(function(node) { if (value == null && node.semantics != null && node.semantics.value != null) value = node.semantics.value; });
    return value == null ? "" : value;
  }

  static function selectAll(fonts:FontCollection, modifiers:Int):String {
    var ui = new UiContext(null, fonts);
    var frame = new LayoutFrame(240.0, 60.0);
    var field = new TextField("name", "abc");
    var root = ui.submit(field, frame);
    check(ui.focusWidget(root.id), "The field did not take focus");
    ui.key(UiEventKind.KeyDown, UiKey.A, modifiers);
    ui.text(UiEventKind.TextInput, "x");
    var result = fieldValue(ui.submit(field, frame));
    ui.dispose();
    return result;
  }

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    var command = #if (mac || ios) UiModifier.Super #else UiModifier.Control #end;
    check(selectAll(fonts, command) == "x", "Select-all did not replace the text");
    check(selectAll(fonts, command | UiModifier.Shift) != "x", "Shift+select-all chord was swallowed as select-all");
    check(selectAll(fonts, command | UiModifier.Alt) != "x", "Alt+select-all chord was swallowed as select-all");
    Sys.println("PASS: only Ctrl/Cmd+A selects all");

    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(240.0); style.height = LayoutAxis.fixed(120.0);
    var tree = new TreeView("items", new Items(), style);
    var frame = new LayoutFrame(240.0, 120.0);
    var root = ui.submit(tree, frame);
    var activated:Array<String> = [];
    var consume = true;
    function enterOn(key:String):Void {
      var y = rowY(root, key);
      ui.pointerDown(60, y, 0); ui.pointerUp(60, y, 0);
      root = ui.submit(tree, frame);
      ui.key(UiEventKind.KeyDown, UiKey.Enter);
      root = ui.submit(tree, frame);
    }
    enterOn("item-0");
    check(tree.isExpanded("item-0"), "Enter without a handler no longer toggles a branch");
    tree.setExpanded("item-0", false);
    tree.onActivate = function(key, _) { activated.push(key); return consume; };
    root = ui.submit(tree, frame);
    enterOn("item-0");
    check(activated.join(",") == "item-0" && !tree.isExpanded("item-0"), "Enter did not activate, or still toggled: " + activated.join(","));
    enterOn("item-1");
    check(activated.join(",") == "item-0,item-1", "Enter did not activate a leaf");
    consume = false;
    enterOn("item-0");
    check(activated.length == 3 && tree.isExpanded("item-0"), "A declining handler did not fall back to toggling");
    Sys.println("PASS: TreeView onActivate on Enter, with fallback");
    ui.dispose(); fonts.dispose(); runtime.dispose();
    return 0;
  }
}
