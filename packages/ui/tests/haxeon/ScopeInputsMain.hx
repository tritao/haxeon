import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.IconButton;

/** Final component inputs include action ownership, authored style, and accessible presentation. */
class ScopeInputsMain {
  static var invoked = 0;
  static function action():Void invoked++;
  static function otherAction():Void invoked += 2;
  static function main():Int {
    var activate = action;
    var alternate = otherAction;
    var left = new Button("Save", null, activate, "save");
    var equal = new Button("Save", null, activate, "save");
    if (!left.inputsEqual(equal) || !equal.inputsEqual(left)) return 1;
    if (left.inputsEqual(new Button("Save", null, alternate, "save"))) return 2;
    if (left.inputsEqual(new Button("Save", null, activate, "save", false))) return 3;
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(90);
    if (left.inputsEqual(new Button("Save", style, activate, "save"))) return 4;
    if (left.inputsEqual(new Button(
      "Save",
      null,
      activate,
      "save",
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      "Save document"
    ))) return 5;
    if (left.inputsEqual(new Button("Save", null, activate, "save", null, null, true))) return 6;
    var classed = new Button("Save", null, activate, "save", null, null, null, ["toolbar"]);
    if (!classed.inputsEqual(new Button("Save", null, activate, "save", null, null, null, ["toolbar"]))) return 12;
    if (classed.inputsEqual(new Button("Save", null, activate, "save", null, null, null, ["other"]))) return 13;
    var icon = new IconButton("save-icon", IconName.Check, "Save", activate);
    var equalIcon = new IconButton("save-icon", IconName.Check, "Save", activate);
    if (!icon.inputsEqual(equalIcon) || left.inputsEqual(icon) || icon.inputsEqual(left)) return 7;
    if (icon.inputsEqual(new IconButton("save-icon", IconName.Check, "Save", alternate))) return 8;
    #if !wasm
    var before = hl.Gc.totalAllocated();
    #end
    for (_ in 0...1024) if (!left.inputsEqual(equal) || !icon.inputsEqual(equalIcon)) return 9;
    #if !wasm
    if (hl.Gc.totalAllocated() != before) return 10;
    #end
    return invoked == 0 ? 42 : 11;
  }
}
