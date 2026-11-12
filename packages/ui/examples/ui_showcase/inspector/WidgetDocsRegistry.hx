package inspector;

import haxeon.ui.Image;

import haxeon.ui.widgets.collections.ListView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.ProgressBar;
import haxeon.ui.widgets.controls.ProgressMode;
import haxeon.ui.widgets.controls.Radio;
import haxeon.ui.widgets.controls.RadioGroup;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.controls.Toolbar;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.Dialog;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;


import haxeon.ui.Rect;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;

/** API synopsis keyed by the UI enum case index stored in inspector snapshots. */
class WidgetDocsRegistry {
  public static function describe(role:Int): {description: String, behavior: String, code: String} {
    return switch role {
      case Type.enumIndex(AccessibilityRole.Button):
        {
          description: "A compositional action control. Haxe owns its interaction state and semantic action; the render tree contains a box and label.",
          behavior: "Activate with click, Enter or Space. It participates in keyboard focus and exposes an Activate accessibility action.",
          code: 'var save = new Button("Save changes", style, onActivate, "save", true, ButtonVariant.Primary);'
        };
      case Type.enumIndex(AccessibilityRole.Checkbox):
        {
          description: "A boolean selection control composed from ordinary Haxe layout and paint nodes.",
          behavior: "Click or press Space to toggle. Checked state is reflected in the semantic value and state bits.",
          code: 'new Checkbox("show-labels", "Show labels", checked, onChange)'
        };
      case Type.enumIndex(AccessibilityRole.Radio):
        {
          description: "One option in an exclusive radio selection group.",
          behavior: "Arrow keys move between enabled options; Space or Enter selects the focused option.",
          code: 'new RadioGroup("density", options, selected, onChange)'
        };
      case Type.enumIndex(AccessibilityRole.TextField):
        {
          description: "An editable text control backed by Haxeon editor state and native text-input services.",
          behavior: "Pointer hit testing positions the caret; keyboard selection/editing and platform clipboard and IME are supported where available.",
          code: 'new TextField("name", value, onChange, style, "Display name")'
        };
      case Type.enumIndex(AccessibilityRole.Slider):
        {
          description: "A continuous range control with pointer, keyboard and semantic value support.",
          behavior: "Drag the thumb or track; arrow keys and accessibility increment/decrement adjust the snapped value.",
          code: 'new Slider("volume", "Volume", value, 0, 1, 0.01, onChange)'
        };
      case Type.enumIndex(AccessibilityRole.ScrollArea):
        {
          description: "A clipped viewport that translates persistent content using Haxe-owned scroll state.",
          behavior: "Wheel, touch/drag, and semantic forward/back actions update the scroll controller.",
          code: 'new ScrollView("results", content, style, ScrollAxis.Vertical)'
        };
      case Type.enumIndex(AccessibilityRole.List), Type.enumIndex(AccessibilityRole.ListItem):
        {
          description: "A list container or a realized item within a data-oriented view.",
          behavior: "The model-backed list builds only visible rows plus a small overscan window, preserves stable item keys, and exposes collection semantics.",
          code: 'new ListView("rows", model, style, controller, viewportHeight)'
        };
      case Type.enumIndex(AccessibilityRole.Image):
        {
          description: "A rendered image with an optional accessible name.",
          behavior: "The image participates in normal layout, clipping and render order.",
          code: 'new ImageView("avatar", image, "Profile photo")'
        };
      case Type.enumIndex(AccessibilityRole.Heading):
        {
          description: "A heading that identifies a section of the current demo.",
          behavior: "Headings expose a navigable semantic role while rendering with the shared text pipeline.",
          code: 'new Text("Section title", headingStyle)'
        };
      case Type.enumIndex(AccessibilityRole.Group):
        {
          description: "A layout or grouping node in the Haxe-owned render tree.",
          behavior: "It composes children and contributes resolved bounds, clipping and z-order without adding a native widget abstraction.",
          code: 'new Column("settings", [keyed("name", nameField)])'
        };
      case Type.enumIndex(AccessibilityRole.Switch):
        {
          description: "A two-position control with switch semantics and Haxe-owned checked state.",
          behavior: "Click or press Space to toggle. Checked state is announced as a switch value.",
          code: 'new Toggle("notifications", "Notifications", enabled, onChange)'
        };
      case Type.enumIndex(AccessibilityRole.ComboBox):
        {
          description: "A typed selection control with either a compact trigger or an editable query field and a keyboard-navigable option list.",
          behavior: "Click or press Enter/Space to open. ComboBox text filters options; arrow keys move between enabled options; long lists scroll, Enter selects, Escape or an outside click closes, and the list stays anchored to the control.",
          code: 'new ComboBox("density", options, selected, onChange)'
        };
      case Type.enumIndex(AccessibilityRole.ProgressBar):
        {
          description: "A non-interactive determinate or indeterminate indicator driven by the shared animation scheduler.",
          behavior: "Determinate values animate visually while accessibility receives the current value immediately. Indeterminate mode reports busy state and respects reduced motion.",
          code: 'var progress = new ProgressBar("upload", value, 0, 1, "Upload progress");\nprogress.mode = ProgressMode.Indeterminate;'
        };
      case Type.enumIndex(AccessibilityRole.Dialog):
        {
          description: "A modal surface for a focused task, composed above the application tree.",
          behavior: "Dismiss or complete the task with its controls; modal semantics and focus are exposed with the dialog.",
          code: 'new Dialog("confirm", "Confirm", content, onDismiss)'
        };
      case Type.enumIndex(AccessibilityRole.Menu),
        Type.enumIndex(AccessibilityRole.MenuBar), Type.enumIndex(AccessibilityRole.MenuItem):
        {
          description: "A command surface or one of its actionable menu entries.",
          behavior: "Menu commands expose their labels, enabled state and activation action.",
          code: 'new Menu("file-menu", items, width, height, onDismiss)'
        };
      case Type.enumIndex(AccessibilityRole.TabList),
        Type.enumIndex(AccessibilityRole.Tab), Type.enumIndex(AccessibilityRole.TabPanel):
        {
          description: "A tab navigation surface with an active tab and associated panel.",
          behavior: "Use arrow keys to move between tabs and Enter or Space to activate the focused tab.",
          code: 'new Tabs("settings", tabs, selected, onChange)'
        };
      default:
        {
          description: "A render primitive produced by a Haxe widget or layout composition.",
          behavior: "Geometry and clipping are resolved natively; events and semantic identity remain connected to this Haxe node.",
          code: 'new Text("Hello, Haxeon UI")'
        };
    };
  }

  public static function roleName(role:Int):String {
    return switch role {
      case Type.enumIndex(AccessibilityRole.Group):
        "Group";
      case Type.enumIndex(AccessibilityRole.Button):
        "Button";
      case Type.enumIndex(AccessibilityRole.Checkbox):
        "Checkbox";
      case Type.enumIndex(AccessibilityRole.Radio):
        "Radio";
      case Type.enumIndex(AccessibilityRole.Text):
        "Text";
      case Type.enumIndex(AccessibilityRole.TextField):
        "TextField";
      case Type.enumIndex(AccessibilityRole.Link):
        "Link";
      case Type.enumIndex(AccessibilityRole.Image):
        "Image";
      case Type.enumIndex(AccessibilityRole.Heading):
        "Heading";
      case Type.enumIndex(AccessibilityRole.List):
        "List";
      case Type.enumIndex(AccessibilityRole.ListItem):
        "ListItem";
      case Type.enumIndex(AccessibilityRole.Slider):
        "Slider";
      case Type.enumIndex(AccessibilityRole.ScrollArea):
        "ScrollArea";
      case Type.enumIndex(AccessibilityRole.Dialog):
        "Dialog";
      case Type.enumIndex(AccessibilityRole.Menu):
        "Menu";
      case Type.enumIndex(AccessibilityRole.MenuBar):
        "MenuBar";
      case Type.enumIndex(AccessibilityRole.MenuItem):
        "MenuItem";
      case Type.enumIndex(AccessibilityRole.TabList):
        "TabList";
      case Type.enumIndex(AccessibilityRole.Tab):
        "Tab";
      case Type.enumIndex(AccessibilityRole.TabPanel):
        "TabPanel";
      case Type.enumIndex(AccessibilityRole.Switch):
        "Switch";
      case Type.enumIndex(AccessibilityRole.ProgressBar):
        "ProgressBar";
      case Type.enumIndex(AccessibilityRole.ComboBox):
        "ComboBox";
      case Type.enumIndex(AccessibilityRole.Collection):
        "Collection";
      case Type.enumIndex(AccessibilityRole.CollectionItem):
        "CollectionItem";
      case Type.enumIndex(AccessibilityRole.Grid):
        "Grid";
      case Type.enumIndex(AccessibilityRole.Row):
        "Row";
      case Type.enumIndex(AccessibilityRole.Cell):
        "Cell";
      case Type.enumIndex(AccessibilityRole.ColumnHeader):
        "ColumnHeader";
      case Type.enumIndex(AccessibilityRole.RowHeader):
        "RowHeader";
      case Type.enumIndex(AccessibilityRole.Tree):
        "Tree";
      case Type.enumIndex(AccessibilityRole.TreeItem):
        "TreeItem";
      case Type.enumIndex(AccessibilityRole.Separator):
        "Separator";
      case Type.enumIndex(AccessibilityRole.Toolbar):
        "Toolbar";
      case Type.enumIndex(AccessibilityRole.Status):
        "Status";
      case Type.enumIndex(AccessibilityRole.Alert):
        "Alert";
      default:
        "Text";
    };
  }

  public static function visualName(kind:Int):String {
    return switch kind {
      case 1:
        "Box";
      case 2:
        "Text";
      case 3:
        "Image";
      case 4:
        "Custom";
      default:
        "Unknown";
    };
  }

  public static function semanticStateNames(states:AccessibilityState):String {
    var values:Array<String> = [];
    if (states.contains(AccessibilityState.Focusable)) values.push("Focusable");
    if (states.contains(AccessibilityState.Focused)) values.push("Focused");
    if (states.contains(AccessibilityState.Selected)) values.push("Selected");
    if (states.contains(AccessibilityState.Checked)) values.push("Checked");
    if (states.contains(AccessibilityState.Disabled)) values.push("Disabled");
    if (states.contains(AccessibilityState.ReadOnly)) values.push("ReadOnly");
    if (states.contains(AccessibilityState.Multiline)) values.push("Multiline");
    if (states.contains(AccessibilityState.Password)) values.push("Password");
    if (states.contains(AccessibilityState.Expanded)) values.push("Expanded");
    return values.length == 0 ? "(none)" : values.join(", ");
  }

  public static function actionNames(actions:AccessibilityAction):String {
    var values:Array<String> = [];
    if (actions.contains(AccessibilityAction.Activate)) values.push("Activate");
    if (actions.contains(AccessibilityAction.Focus)) values.push("Focus");
    if (actions.contains(AccessibilityAction.SetValue)) values.push("SetValue");
    if (actions.contains(AccessibilityAction.SetSelection)) values.push("SetSelection");
    if (actions.contains(AccessibilityAction.Increment)) values.push("Increment");
    if (actions.contains(AccessibilityAction.Decrement)) values.push("Decrement");
    if (actions.contains(AccessibilityAction.ScrollForward)) values.push("ScrollForward");
    if (actions.contains(AccessibilityAction.ScrollBackward)) values.push("ScrollBackward");
    if (actions.contains(AccessibilityAction.MoveNext)) values.push("MoveNext");
    if (actions.contains(AccessibilityAction.MovePrevious)) values.push("MovePrevious");
    return values.length == 0 ? "(none)" : values.join(", ");
  }

  public static function rectText(rect:Rect):String return '${Std.int(rect.x)},${Std.int(rect.y)} ${Std.int(rect.width)}×${Std.int(rect.height)}';
}
