package nativekit.ui.lab;

import Color;
import Insets;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import nativekit.ui.core.UiContext;
import nativekit.ui.core.View;
import nativekit.ui.debug.UiNodeSnapshot;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;
import nativekit.ui.widgets.controls.Checkbox;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.ProgressBar;
import nativekit.ui.widgets.controls.ProgressMode;
import nativekit.ui.widgets.controls.RadioGroup;
import nativekit.ui.widgets.controls.RadioOption;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.controls.Select;
import nativekit.ui.widgets.controls.SelectOption;
import nativekit.ui.widgets.layout.SizedBox;
import nativekit.ui.widgets.layout.SplitOrientation;
import nativekit.ui.widgets.layout.SplitSide;
import nativekit.ui.widgets.layout.SplitView;
import nativekit.ui.widgets.layout.SplitViewOptions;
import nativekit.ui.widgets.controls.Slider;
import nativekit.ui.widgets.controls.TabItem;
import nativekit.ui.widgets.controls.Tabs;
import nativekit.ui.widgets.text.Text;
import nativekit.ui.widgets.text.TextArea;
import nativekit.ui.widgets.text.TextField;
import nativekit.ui.widgets.controls.Toggle;

/** Interactive Storybook-style surface backed by ordinary UIKit views. */
class ComponentLab {
  public final stories:Array<ComponentStory>;
  var selectedId:String;
  var textValue:String = "Editable text";
  var checkboxValue:Bool = true;
  var selectValue:String = "balanced";
  var sliderValue:Float = 0.62;
  var radioValue:String = "middle";
  var multilineValue:String = "A multiline editor\nwith deterministic content.";
  var previewWidth:Float = 0.0;

  public function new(?initialStory:String, ?registry:ComponentStoryRegistry) {
    stories = registry == null ? makeStories() : registry.all();
    if (stories.length == 0) throw "Component Lab requires at least one story";
    selectedId = initialStory == null || find(initialStory) == null
      ? stories[0].id : initialStory;
  }

  public function view(ui:UiContext):View {
    var selected = find(selectedId);
    if (selected == null) selected = stories[0];

    var sidebarRows:Array<KeyedView> = [];
    var previousGroup = "";
    for (story in stories) {
      if (story.group != previousGroup) {
        previousGroup = story.group;
        sidebarRows.push(new KeyedView("group:" + story.group,
          new Text(story.group.toUpperCase(), null, Color.rgba(0.43, 0.55, 0.7, 1.0))));
      }
      var captured = story;
      var button = new Button(story.title, null, function() {
        selectedId = captured.id;
        ui.commands.refresh();
      }, "story:" + story.id);
      button.variant = ButtonVariant.Navigation;
      button.selected = story.id == selected.id;
      sidebarRows.push(new KeyedView(story.id, button));
    }

    var sidebarStyle = new LayoutStyle();
    sidebarStyle.width = LayoutAxis.fixed(250.0);
    sidebarStyle.height = LayoutAxis.grow();
    sidebarStyle.padding = new Insets(12.0, 14.0, 12.0, 14.0);
    sidebarStyle.childGap = 8.0;
    sidebarStyle.background = Color.rgba(0.035, 0.045, 0.065, 1.0);

    var canvasStyle = new LayoutStyle();
    canvasStyle.width = LayoutAxis.grow();
    canvasStyle.height = LayoutAxis.grow();
    canvasStyle.padding = new Insets(28.0, 24.0, 28.0, 24.0);
    canvasStyle.childGap = 18.0;
    canvasStyle.background = Color.rgba(0.055, 0.065, 0.085, 1.0);

    var previewStyle = new LayoutStyle();
    previewStyle.width = previewWidth <= 0.0 ? LayoutAxis.grow() : LayoutAxis.fixed(previewWidth);
    previewStyle.height = LayoutAxis.grow();
    previewStyle.padding = new Insets(24.0, 24.0, 24.0, 24.0);
    previewStyle.background = Color.rgba(0.025, 0.032, 0.048, 1.0);

    var content = new Column("lab-canvas", [
      new KeyedView("eyebrow", new Text(selected.group.toUpperCase(), null,
        Color.rgba(0.43, 0.62, 0.88, 1.0))),
      new KeyedView("title", new Text(selected.title)),
      new KeyedView("description", new Text(selected.description, null,
        Color.rgba(0.62, 0.68, 0.78, 1.0))),
      new KeyedView("environment", environmentToolbar(ui)),
      new KeyedView("preview", new Column("story-preview", [
        new KeyedView("story", selected.build())
      ], previewStyle))
    ], canvasStyle);

    var rootStyle = new LayoutStyle();
    rootStyle.width = LayoutAxis.grow();
    rootStyle.height = LayoutAxis.grow();
    rootStyle.direction = LayoutDirection.LeftToRight;
    return new Row("component-lab", [
      new KeyedView("catalog", new Column("story-catalog", sidebarRows, sidebarStyle)),
      new KeyedView("content", content),
      new KeyedView("inspector", inspector(ui))
    ], rootStyle);
  }

  public function diagnosticState():Dynamic return {
    selectedStory: selectedId,
    storyIds: [for (story in stories) story.id],
    controls: {
      text: textValue,
      checked: checkboxValue,
      select: selectValue
    },
    environment: {previewWidth: previewWidth}
  };

  function environmentToolbar(ui:UiContext):View {
    var items:Array<KeyedView> = [new KeyedView("label", new Text("Preview width"))];
    for (entry in [
      {key: "auto", label: "Auto", width: 0.0},
      {key: "compact", label: "480", width: 480.0},
      {key: "wide", label: "768", width: 768.0}
    ]) {
      var captured = entry;
      var button = new Button(entry.label, null, function() {
        previewWidth = captured.width;
        ui.commands.refresh();
      }, "width:" + entry.key);
      button.variant = ButtonVariant.Navigation;
      button.selected = previewWidth == entry.width;
      items.push(new KeyedView(entry.key, button));
    }
    return new Row("lab-environment", items, rowStyle());
  }

  function inspector(ui:UiContext):View {
    var active:Null<UiNodeSnapshot> = null;
    for (node in ui.inspect())
      if (node.focused || node.hovered || node.pressed) active = node;
    var lines:Array<KeyedView> = [
      new KeyedView("heading", new Text("INSPECTOR", null,
        Color.rgba(0.43, 0.55, 0.7, 1.0)))
    ];
    if (active == null)
      lines.push(new KeyedView("empty", new Text("Focus or hover a component to inspect it.")));
    else {
      var node:UiNodeSnapshot = cast active;
      lines.push(new KeyedView("type", new Text("Type: " +
        (node.styleType == null ? "untyped" : node.styleType))));
      lines.push(new KeyedView("bounds", new Text("Bounds: " + round(node.bounds.x) + ", " +
        round(node.bounds.y) + "  " + round(node.bounds.width) + " × " +
        round(node.bounds.height))));
      lines.push(new KeyedView("role", new Text("Role: " + node.role)));
      lines.push(new KeyedView("states", new Text("States: " + node.interactionStates)));
      lines.push(new KeyedView("label", new Text("Label: " +
        (node.label == null ? "—" : node.label))));
      lines.push(new KeyedView("actions", new Text("Actions: " + node.actions)));
    }
    var metrics = ui.frameMetrics;
    if (metrics != null) {
      lines.push(new KeyedView("metrics-heading", new Text("FRAME", null,
        Color.rgba(0.43, 0.55, 0.7, 1.0))));
      lines.push(new KeyedView("nodes", new Text("Nodes: " + metrics.nodeCount)));
      lines.push(new KeyedView("submit", new Text("Submit: " +
        round(metrics.submitSeconds * 1000.0) + " ms")));
      lines.push(new KeyedView("render", new Text("Render: " +
        round(metrics.renderSeconds * 1000.0) + " ms")));
    }
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(260.0);
    style.height = LayoutAxis.grow();
    style.padding = new Insets(14.0, 14.0, 14.0, 14.0);
    style.childGap = 9.0;
    style.background = Color.rgba(0.035, 0.045, 0.065, 1.0);
    return new Column("lab-inspector", lines, style);
  }

  static function round(value:Float):Float return Math.round(value * 100.0) / 100.0;

  function makeStories():Array<ComponentStory> return [
    new ComponentStory("button/states", "Button states", "Controls",
      "Primary, secondary, selected, and disabled states in one deterministic frame.",
      buttonStates),
    new ComponentStory("text-field/editing", "Text field", "Controls",
      "Editable text with retained selection, keyboard, and IME state.", textFieldStory),
    new ComponentStory("selection/controls", "Selection controls", "Controls",
      "Checkbox and typed select controls with live local state.", selectionStory),
    new ComponentStory("controls/value", "Value controls", "Controls",
      "Slider, progress, toggle, and radio states over shared theme tokens.", valueControlsStory),
    new ComponentStory("text/multiline", "Multiline text", "Text & Input",
      "A constrained multiline editor for wrapping, selection, and IME testing.", multilineStory),
    new ComponentStory("navigation/tabs", "Tabs", "Navigation",
      "A constrained tab strip whose selected page fills the preview width.", tabsStory),
    new ComponentStory("layout/split-view", "Split view", "Layout",
      "A draggable two-pane split with fixed minimum and maximum extents.", splitStory),
    new ComponentStory("design/tokens", "Design tokens", "Foundations",
      "Canonical control rhythm, spacing, selection, and disabled treatments.", tokensStory)
  ];

  function buttonStates():View {
    var primary = new Button("Primary", null, function() {}, "primary");
    primary.variant = ButtonVariant.Primary;
    var secondary = new Button("Navigation", null, function() {}, "navigation");
    secondary.variant = ButtonVariant.Navigation;
    var selected = new Button("Selected", null, function() {}, "selected");
    selected.selected = true;
    var disabled = new Button("Disabled", null, null, "disabled");
    disabled.enabled = false;
    return new Row("button-states", [
      new KeyedView("primary", primary),
      new KeyedView("navigation", secondary),
      new KeyedView("selected", selected),
      new KeyedView("disabled", disabled)
    ], rowStyle());
  }

  function textFieldStory():View {
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(360.0);
    return new TextField("editable-text", textValue, function(next) {
      textValue = next;
    }, style);
  }

  function selectionStory():View {
    var selectStyle = new LayoutStyle();
    selectStyle.width = LayoutAxis.fixed(220.0);
    return new Row("selection-controls", [
      new KeyedView("checkbox", new Checkbox("enabled", "Enabled", checkboxValue,
        function(next) checkboxValue = next)),
      new KeyedView("select", new Select<String>("quality", [
        new SelectOption<String>("fast", "Fast", "fast"),
        new SelectOption<String>("balanced", "Balanced", "balanced"),
        new SelectOption<String>("quality", "High quality", "quality")
      ], selectValue, function(next) selectValue = next, selectStyle))
    ], rowStyle());
  }

  function tabsStory():View {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    style.height = LayoutAxis.fixed(240.0);
    return new Tabs("lab-tabs", [
      new TabItem("overview", "Overview", new Text("Overview content")),
      new TabItem("details", "Details", new Text("Detailed component information")),
      new TabItem("disabled", "Disabled", new Text("Unavailable"), false)
    ], "overview", null, style);
  }

  function valueControlsStory():View {
    var columnStyle = new LayoutStyle();
    columnStyle.width = LayoutAxis.fixed(480.0);
    columnStyle.childGap = 18.0;
    var slider = new Slider("volume", "Volume", sliderValue, 0.0, 1.0, 0.01,
      function(next) sliderValue = next);
    var progress = new ProgressBar("progress", sliderValue, 0.0, 1.0, "Progress");
    progress.animationDuration = 0.0;
    return new Column("value-controls", [
      new KeyedView("slider", slider),
      new KeyedView("progress", progress),
      new KeyedView("toggle", new Toggle("notifications", "Notifications", checkboxValue,
        function(next) checkboxValue = next)),
      new KeyedView("radio", new RadioGroup("quality", [
        new RadioOption("low", "Low", "low"),
        new RadioOption("middle", "Balanced", "middle"),
        new RadioOption("high", "High", "high")
      ], radioValue, function(next) radioValue = next))
    ], columnStyle);
  }

  function multilineStory():View {
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(520.0);
    style.height = LayoutAxis.fixed(220.0);
    return new TextArea("multiline-editor", multilineValue,
      function(next) multilineValue = next, style, "Example notes");
  }

  function tokensStory():View {
    var columnStyle = new LayoutStyle();
    columnStyle.width = LayoutAxis.fixed(560.0);
    columnStyle.childGap = 16.0;
    var disabled = new Button("Disabled action", null, null, "token-disabled");
    disabled.enabled = false;
    var nav = new Button("Navigation item", null, function() {}, "token-navigation");
    nav.variant = ButtonVariant.Navigation;
    nav.selected = true;
    var primary = new Button("Primary action", null, function() {}, "token-primary");
    primary.variant = ButtonVariant.Primary;
    return new Column("design-tokens", [
      new KeyedView("heading", new Text("Typography / Heading")),
      new KeyedView("body", new Text("Body text establishes the default reading rhythm.")),
      new KeyedView("muted", new Text("Muted text supports secondary information.", null,
        Color.rgba(0.62, 0.68, 0.78, 1.0))),
      new KeyedView("actions", new Row("token-actions", [
        new KeyedView("primary", primary),
        new KeyedView("navigation", nav),
        new KeyedView("disabled", disabled)
      ], rowStyle()))
    ], columnStyle);
  }

  function splitStory():View {
    var options = new SplitViewOptions();
    options.orientation = SplitOrientation.Horizontal;
    options.resizableSide = SplitSide.Leading;
    options.extent = 240.0;
    options.minimumExtent = 120.0;
    options.maximumExtent = 420.0;
    var splitStyle = new LayoutStyle();
    splitStyle.width = LayoutAxis.grow();
    splitStyle.height = LayoutAxis.fixed(320.0);
    options.style = splitStyle;
    return new SplitView("lab-split",
      new SizedBox("leading", new Text("Leading pane"), LayoutAxis.grow(), LayoutAxis.grow()),
      new SizedBox("trailing", new Text("Trailing pane"), LayoutAxis.grow(), LayoutAxis.grow()),
      options);
  }

  function find(id:String):Null<ComponentStory> {
    for (story in stories) if (story.id == id) return story;
    return null;
  }

  static function rowStyle():LayoutStyle {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    style.direction = LayoutDirection.LeftToRight;
    style.childGap = 12.0;
    return style;
  }
}
