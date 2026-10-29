import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutAxis;
import haxeon.ui.debug.AccessibilityAudit;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.SelectOption;

class ComboBoxTests {
 static function check(value:Bool, message:String):Void { if (!value) throw message; }
 static function main():Void {
  var fonts = FontCollection.create();
  fonts.add(Sys.getEnv("NKUI_TEST_FONT_PATH"));
  var ui = new UiContext(null, fonts);
  var changes = 0;
  var combo = new ComboBox<String>("combo", [new SelectOption("one", "One", "one"),
   new SelectOption("two", "Two", "two"), new SelectOption("blocked", "Blocked", "blocked", false)],
   "one", function(_) changes++);
  var root:RenderNode = null;
  function build():Void { root = ui.submit(combo, new LayoutFrame(400, 280)); }
  function input():RenderNode return root.children[0].children[0];
  function arrow():RenderNode return root.children[0].children[1].children[0];
  function open():Bool return root.children.length == 2;
  function click(node:RenderNode):Void {
   var b = node.globalBounds();
   ui.pointerDown(b.x + b.width / 2, b.y + b.height / 2, 0);
   ui.pointerUp(b.x + b.width / 2, b.y + b.height / 2, 0);
   build();
  }
  build(); build();
  var bounds = input().globalBounds(), toggleBounds = arrow().globalBounds();
  check(Math.abs(toggleBounds.x + toggleBounds.width - bounds.x - bounds.width) < 0.01,
   "Arrow is not aligned with the editor's right edge");
  var arrowSemantics:Semantics = cast arrow().semantics;
  check(AccessibilityAudit.isValid(root), "Invalid ComboBox accessibility tree");
  check(arrowSemantics.role == AccessibilityRole.Button && arrowSemantics.label == "Show options", "Arrow is not an accessible button");
  ui.focusWidget(input().id);
  ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control); build();
  var before:Semantics = cast input().semantics;
  for (_ in 0...3) {
   click(arrow()); check(open(), "Arrow failed to open");
   var expanded:Semantics = cast arrow().semantics;
   check(expanded.label == "Hide options" && (expanded.states & AccessibilityState.Expanded) != 0, "Arrow did not expose expanded state");
   click(arrow()); check(!open(), "Arrow failed to close or reopened through the editor");
   var after:Semantics = cast input().semantics;
   check(after.selectionStart == before.selectionStart && after.selectionEnd == before.selectionEnd && after.value == "One",
    "Arrow edited the query or selection");
   check(ui.focus.focusedId.equals(input().id), "Closing did not restore editor focus");
  }
  check(ui.accessibilityAction(arrow().id.value, AccessibilityRequest.Expand, null, -1, -1, 1), "Accessible expand failed");
  build(); check(open() && AccessibilityAudit.isValid(root), "Accessible expand did not open a valid tree");
  check(ui.accessibilityAction(arrow().id.value, AccessibilityRequest.Collapse, null, -1, -1, 1), "Accessible collapse failed");
  build(); check(!open(), "Accessible collapse reopened the popup");
  combo.style.width = LayoutAxis.fixed(160); build();
  bounds = input().globalBounds(); toggleBounds = arrow().globalBounds();
  check(Math.abs(toggleBounds.x + toggleBounds.width - bounds.x - bounds.width) < 0.01, "Resize displaced the arrow");
  // Keyboard activation goes through the button, not the editor's submit handler.
  ui.focusWidget(arrow().id); ui.key(UiEventKind.KeyDown, UiKey.Enter); build();
  check(open() && changes == 0, "Keyboard arrow activation selected an option");
  ui.key(UiEventKind.KeyDown, UiKey.Escape); build(); check(!open(), "Escape failed");
  ui.focusWidget(arrow().id); ui.key(UiEventKind.KeyDown, UiKey.Space); build();
  check(open(), "Space did not activate the arrow");
  ui.pointerDown(350, 200, 0); ui.pointerUp(350, 200, 0); build();
  check(!open(), "Outside click failed to dismiss");
  click(input()); check(open(), "Text click did not open options");
  ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
  ui.text(UiEventKind.TextInput, "Tw"); build();
  check(open() && root.children[1].children.length == 1, "Editing did not filter options");
  var option:Semantics = cast root.children[1].children[0].semantics;
  check(option.label == "Two", "Wrong filtered option");
  click(arrow()); check(!open(), "Filtered list did not close");
  click(arrow()); check(open(), "Filtered list did not reopen");
  var query:Semantics = cast input().semantics;
  check(query.value == "Tw", "Reopening replaced the edited query");
  ui.key(UiEventKind.KeyDown, UiKey.Enter); build();
  check(!open() && combo.value == "two" && changes == 1, "Enter did not select the filtered option exactly once");
  combo.enabled = false; build(); click(arrow());
  check(!open() && !arrow().enabled && !arrow().focusable && changes == 1, "Disabled arrow activated");
  ui.dispose(); fonts.dispose();
  Sys.println("PASS: ComboBox arrow toggle, accessible activation, query/selection preservation, filtering, dismissal and disabled state");
 }
}
