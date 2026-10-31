import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.UiKey;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.controls.ProgressBar;
import haxeon.ui.widgets.controls.ProgressMode;
import haxeon.platform.Runtime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.Key;
import haxeon.ui.core.View;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.IconButton;
import haxeon.ui.widgets.controls.Radio;
import haxeon.ui.widgets.controls.RadioGroup;
import haxeon.ui.widgets.controls.RadioOption;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;

/** A control the way a container uses one: built, then given a listener, a style change and an overlay child by its caller. */
private class DecoratedControl implements View {
  public var presses = 0;
  public final key:String;
  final make:BuildContext->RenderNode;

  public function new(key:String, make:BuildContext->RenderNode) {
    this.key = key;
    this.make = make;
  }

  public function build(context:BuildContext):RenderNode {
    var node = make(context);
    node.on(UiEventKind.PointerDown, function(_) presses++);
    node.layout.style.zIndex = 3;
    // As DockWorkspace does with tab buttons: an overlay child added by the caller.
    var overlayStyle = new LayoutStyle();
    overlayStyle.width = LayoutAxis.fixed(5.5);
    overlayStyle.height = LayoutAxis.fixed(7.5);
    node.add(new RenderNode(context.id("caller-overlay"), haxeon.ui.LayoutVisualKind.Box, overlayStyle));
    return node;
  }
}

private class WindowItems implements haxeon.ui.widgets.collections.ListViewModel {
  public function new() {}
  public function count():Int return 40;
  public function keyAt(index:Int):String return "row-" + index;
  public function estimatedExtent():Float return 20;
  public function extentIsUniform():Bool return true;
  public function extentAt(index:Int):Float return 20;
  public function extentRevisionAt(index:Int):Int return 0;
  public function totalExtent():Null<Float> return 800;
  public function revision():Int return 0;
  public function buildItem(index:Int):View return new Text("row-" + index);
}

/** Records the controls' actual drawing, including caller paint, without depending on native resource IDs. */
private class PaintTrace extends Canvas {
  public final rectangles:Array<Rect> = [];
  public final colors:Array<Color> = [];
  public function new() super();
  public override function fillRect(rect:Rect, color:Color):Void {
    rectangles.push(rect);
    colors.push(color);
  }
  public function same(other:PaintTrace):Bool {
    if (rectangles.length != other.rectangles.length) return false;
    for (index in 0...rectangles.length)
      if (!haxeon.Equality.equals(rectangles[index], other.rectangles[index]) ||
          !haxeon.Equality.equals(colors[index], other.colors[index])) return false;
    return true;
  }
}

private class MotionRig {
  public final ui:UiContext;
  public final slider:Slider;
  public final progress:ProgressBar;
  public final decorated:Array<DecoratedControl>;
  public var sliderBuilt:Null<RenderNode>;
  public var progressBuilt:Null<RenderNode>;
  public var panelBuilds = 0;
  final frame = new LayoutFrame(240.0, 140.0);
  final view:View;
  final patched:Bool;
  var submissions = 0;

  public function new(fonts:FontCollection, patched:Bool) {
    this.patched = patched;
    ui = new UiContext(null, fonts);
    ui.buildContext.updateInPlace = patched;
    ui.buildContext.environment.reducedMotion = false;
    slider = new Slider("live-slider", "Live slider", 0.0, 0.0, 1.0, 0.05);
    progress = new ProgressBar("live-progress", 0.0);
    progress.animationDuration = 0.3;
    decorated = [
      new DecoratedControl("slider-host", function(context) {
        var node = slider.build(context);
        sliderBuilt = node;
        return decorate(node);
      }),
      new DecoratedControl("progress-host", function(context) {
        var node = progress.build(context);
        progressBuilt = node;
        return decorate(node);
      })
    ];
    view = new RetainedView("motion-panel", function(_) {
      panelBuilds++;
      return new Column("motion-column", [new KeyedView("slider-host", decorated[0]),
        new KeyedView("progress-host", decorated[1])]);
    }, patched ? null : function() return Std.string(panelBuilds));
  }

  function decorate(node:RenderNode):RenderNode {
    node.layout.style.width = LayoutAxis.fixed(180.0);
    node.onPaint(function(canvas, _) canvas.fillRect(new Rect(1.0, 1.0, 2.0, 2.0), Color.rgba(0.2, 0.3, 0.4, 1.0)));
    return node;
  }

  public function submit():RenderNode {
    frame.deltaSeconds = 0.1;
    return ui.submitCached(function() return view, frame, patched ? "motion" : "motion:" + submissions++);
  }
}

/** One UI with a retained panel of controls: buttons, or the other controls that restyle themselves. */
private class Rig {
  public final ui:UiContext;
  public final frame:LayoutFrame;
  public final decorated:Array<DecoratedControl>;
  public var panelBuilds = 0;
  public var clicks = 0;
  public var checked = false;
  public var toggled = false;
  public var chosen = "";
  final view:View;

  /**
   * `scrolling` puts the buttons in a scroll view that overflows, with motion on, so the scrollbar fades frame by frame.
   * `controls` fills the panel with icon buttons, checkboxes, switches and radio options instead of buttons.
   */
  public function new(fonts:FontCollection, restyleInPlace:Bool, scrolling:Bool = false, controls:Bool = false) {
    ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = !scrolling;
    ui.buildContext.updateInPlace = restyleInPlace;
    frame = new LayoutFrame(240.0, controls ? 460.0 : 200.0);
    var rig = this;
    decorated = controls ? [
      new DecoratedControl("decorated-icon", function(context) return new IconButton("decorated-icon", IconName.Search, "Decorated icon", function() rig.clicks++).build(context)),
      new DecoratedControl("decorated-check", function(context) {
        var checkbox:View = new Checkbox("decorated-check", "Decorated check", false, function(_) rig.clicks++);
        return checkbox.build(context);
      }),
      new DecoratedControl("decorated-radio", function(context) return new Radio("decorated-radio", "Decorated radio", "d", false, function(_) rig.clicks++).build(context)),
    ] : [
      new DecoratedControl("decorated", function(context) return new Button("Decorated", null, null, "decorated").build(context)),
    ];
    var panel = new RetainedView("panel", function(_) {
      rig.panelBuilds++;
      var items:Array<KeyedView> = controls ? [
        new KeyedView("icon", new IconButton("icon", IconName.Close, "Close", function() rig.clicks++)),
        new KeyedView("check", new Checkbox("check", "Check", rig.checked, function(value) rig.checked = value)),
        new KeyedView("toggle", new Toggle("toggle", "Toggle", rig.toggled, function(value) rig.toggled = value)),
        new KeyedView("radio", new Radio("radio", "Radio", "r", false, function(_) rig.clicks++)),
        new KeyedView("group", new RadioGroup("group", [new RadioOption("alpha", "Alpha", "a"), new RadioOption("beta", "Beta", "b")], "a",
          function(value) rig.chosen = value)),
        new KeyedView("disabled", new Radio("disabled", "Disabled", "x", false, function(_) rig.clicks++, null, false)),
      ] : [
        new KeyedView("one", new Button("One", null, function() rig.clicks++, "one")),
        new KeyedView("two", new Button("Two", null, function() rig.clicks++, "two")),
      ];
      for (control in rig.decorated) items.push(new KeyedView(control.key, control));
      if (!controls) {
        items.push(new KeyedView("three", new Button("Three", null, function() rig.clicks++, "three")));
        items.push(new KeyedView("four", new Button("Four", null, function() rig.clicks++, "four")));
      }
      var column = new Column("column", items);
      if (!scrolling) return column;
      var style = new LayoutStyle();
      style.width = LayoutAxis.fixed(200.0);
      style.height = LayoutAxis.fixed(90.0);
      return new ScrollView("scroll", column, style, ScrollAxis.Vertical);
    // The reference never reuses its panel, so everything in it, the scrollbar too, is built from scratch on every frame.
    }, restyleInPlace ? null : function() return Std.string(rig.panelBuilds));
    view = panel;
  }

  public function submit():RenderNode {
    frame.deltaSeconds = 0.1;
    return ui.submitCached(function() return view, frame, "panel");
  }
}

/** A self-updating widget whose build puts a listener, a paint callback and a child on its node, each capturing what it shows. */
private class Gauge implements View {
  public var level = 1;
  public var builds = 0;
  /** What the callbacks of the newest build last reported. */
  public var painted = "";
  public var clicked = "";
  public var asText = false;
  public var offset = 0.0;
  public var labelNode:Null<RenderNode>;
  public var id:Null<haxeon.ui.core.WidgetId> = null;

  public function new() {}

  public function build(context:BuildContext):RenderNode {
    return context.withScope(new Key("gauge"), function() {
      var nodeId = context.id("gauge");
      id = nodeId;
      return context.selfUpdating(nodeId, function() {
        builds++;
        var shown = level;
        var style = new LayoutStyle();
        style.width = LayoutAxis.fixed(100.0);
        style.height = LayoutAxis.fixed(30.0);
        style.zIndex = shown;
        var node = new RenderNode(nodeId, asText ? LayoutVisualKind.Text : LayoutVisualKind.Custom, style);
        if (!asText) node.onPaint(function(_, _) painted = "level " + shown, "gauge:" + shown);
        node.on(UiEventKind.Click, function(_) clicked = "level " + shown);
        var label = new RenderNode(context.id("label"), LayoutVisualKind.Text);
        label.layout.text = "level " + shown;
        label.layout.style.transform = haxeon.ui.Transform2D.identity().translated(0, -offset);
        labelNode = label;
        node.add(label);
        return node;
      });
    });
  }
}

/** A text field given a listener by its caller. */
private class FieldDecoration implements View {
  final field:TextField;
  final onPress:Void->Void;

  public function new(field:TextField, onPress:Void->Void) {
    this.field = field;
    this.onPress = onPress;
  }

  public function build(context:BuildContext):RenderNode {
    var node = field.build(context);
    node.on(UiEventKind.PointerDown, function(_) onPress());
    return node;
  }
}

/** What a container does to a node after building it: a listener, a style change, a child, and its own semantics. */
private class DecoratedGauge implements View {
  public var presses = 0;
  public final gauge:Gauge;

  public function new(gauge:Gauge) this.gauge = gauge;

  public function build(context:BuildContext):RenderNode {
    var node = gauge.build(context);
    node.on(UiEventKind.Click, function(_) presses++);
    node.layout.style.positionX = 4.0;
    node.semantics = new Semantics(AccessibilityRole.Button, "decorated");
    node.add(new RenderNode(context.id("caller-child"), LayoutVisualKind.Box));
    return node;
  }
}

private class TabsRig {
  public final ui:UiContext;
  public final tabs:haxeon.ui.widgets.controls.Tabs;
  public final decorated:DecoratedControl;
  public var panelBuilds = 0;
  public var changes = 0;
  public var closes = 0;
  final view:View;
  final patched:Bool;
  final frame = new LayoutFrame(320, 240);
  var submissions = 0;
  public function new(fonts:FontCollection, patched:Bool) {
    this.patched = patched;
    ui = new UiContext(null, fonts);
    ui.buildContext.updateInPlace = patched;
    ui.buildContext.environment.reducedMotion = true;
    var first = new haxeon.ui.widgets.controls.TabItem("first", "First", new RetainedView("first-page", _ -> new Text("First page")));
    var second = new haxeon.ui.widgets.controls.TabItem("second", "Second", new RetainedView("second-page", _ -> new Text("Second page")));
    var disabled = new haxeon.ui.widgets.controls.TabItem("disabled", "Disabled", new Text("Disabled page"), false);
    first.onClose = () -> closes++;
    second.onClose = () -> closes++;
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(280);
    style.height = LayoutAxis.fixed(200);
    tabs = new haxeon.ui.widgets.controls.Tabs("local-tabs", [first, disabled, second], "first", _ -> changes++, style);
    tabs.headerRevision = () -> "headers";
    decorated = new DecoratedControl("tabs-host", context -> tabs.build(context));
    view = new RetainedView("tabs-panel", _ -> {panelBuilds++; return decorated;},
      patched ? null : () -> Std.string(panelBuilds));
  }
  public function submit():RenderNode return ui.submitCached(() -> view, frame, patched ? "tabs" : "tabs:" + submissions++);
}

private class PopupRig implements View {
  public final ui:UiContext;
  public final popup:haxeon.ui.widgets.controls.SelectionPopup;
  public var result:Null<haxeon.ui.widgets.controls.SelectionPopup.SelectionPopupResult>;
  public var caller:Null<RenderNode>;
  public var panelBuilds = 0;
  public var chosen = 0;
  public var active = 0;
  public var selections = 0;
  public var closes = 0;
  public var presses = 0;
  public var backgroundWheels = 0;
  final view:View;
  final patched:Bool;
  final frame = new LayoutFrame(240, 240);
  var submissions = 0;
  public function new(fonts:FontCollection, patched:Bool) {
    this.patched = patched;
    ui = new UiContext(null, fonts);
    ui.buildContext.updateInPlace = patched;
    ui.buildContext.environment.reducedMotion = true;
    var options:Array<haxeon.ui.widgets.controls.SelectOption<Dynamic>> = [for (index in 0...24)
      new haxeon.ui.widgets.controls.SelectOption<Dynamic>("option-" + index, "Option " + index, index, index != 3)];
    var next = function(index:Int, direction:Int):Int {
      var candidate = index;
      for (_ in 0...options.length) {
        candidate = (candidate + direction + options.length) % options.length;
        if (options[candidate].enabled) return candidate;
      }
      return index;
    };
    popup = new haxeon.ui.widgets.controls.SelectionPopup(options, [for (index in 0...24) index], 0, 0,
      0, 0, 8, 8, 150, 36, 150, 36,
      index -> {chosen = index; active = index; selections++;}, () -> closes++, index -> active = index,
      index -> index >= 0 && index < options.length && options[index].enabled, next);
    view = new RetainedView("popup-panel", _ -> {panelBuilds++; return this;},
      patched ? null : () -> Std.string(panelBuilds));
  }
  public function build(context:BuildContext):RenderNode {
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(150);
    style.height = LayoutAxis.fixed(36);
    style.clipToParent = false;
    var root = new RenderNode(context.id("popup-anchor"), LayoutVisualKind.Box, style);
    root.on(UiEventKind.Scroll, _ -> backgroundWheels++);
    var menu = popup.build(context, root);
    result = menu;
    menu.node.layout.style.zIndex = 11;
    menu.node.on(UiEventKind.PointerDown, _ -> presses++);
    menu.node.onPaint((canvas, _) -> canvas.fillRect(new Rect(1, 1, 2, 2), Color.rgba(0.2, 0.3, 0.4, 1)), "caller-popup");
    var overlay = new LayoutStyle();
    overlay.width = LayoutAxis.fixed(3);
    overlay.height = LayoutAxis.fixed(3);
    overlay.positioning = haxeon.ui.LayoutPositioning.Absolute;
    caller = new RenderNode(context.id("popup-caller"), LayoutVisualKind.Box, overlay);
    menu.node.add(caller);
    return root;
  }
  public function menu():haxeon.ui.widgets.controls.SelectionPopup.SelectionPopupResult {
    var value = result;
    if (value == null) throw "Popup is not built";
    return value;
  }
  public function submit():RenderNode return ui.submitCached(() -> view, frame, patched ? "popup" : "popup:" + submissions++);
}

private class UpdatingResources implements View {
  public var enabled = false;
  public var generation = 0;
  public var reading = 0;
  public var created = 0;
  public var disposed = 0;
  public var rootId:Null<haxeon.ui.core.WidgetId>;
  public var childId:Null<haxeon.ui.core.WidgetId>;
  public var value:Null<haxeon.ui.core.State<Int>>;
  public function new() {}
  public function build(context:BuildContext):RenderNode return context.withScope(new Key("updating-resources"), () -> {
    var id = context.id("owner");
    rootId = id;
    return context.selfUpdating(id, () -> {
      var root = new RenderNode(id, LayoutVisualKind.Box);
      if (enabled) root.add(new RetainedView("nested", _ -> new DecoratedControl("inner", context -> {
        var child = context.id("child");
        childId = child;
        return context.selfUpdating(child, () -> {
          var resource = context.resourceState(context.id("resource-" + generation), () -> {created++; return generation;}, _ -> disposed++);
          var state = context.state(context.id("value"), 0);
          value = state;
          var seen = context.observeInt(() -> reading);
          var node = new RenderNode(child, LayoutVisualKind.Box);
          var label = new RenderNode(context.id("label"), LayoutVisualKind.Text);
          label.layout.text = resource.value + ":" + state.value + ":" + seen;
          node.add(label);
          return node;
        });
      })).build(context));
      return root;
    });
  });
}

class RestyleInPlaceTests {
  static function check(value:Bool, message:String):Void if (!value) throw message;

  /** Everything a user could see or interact with, per node. */
  static function signature(root:RenderNode):String {
    var out = new StringBuf();
    root.walk(function(node) {
      var style = node.layout.style, color = style.background, text = node.layout.textColor;
      // State routed onto a node that no widget built from is invisible; a rebuilt node starts without it.
      out.add(node.id.value + "|" + node.styleType + "|" + (node.recordsInteraction ? node.states : -1) + "|" + color.red + "," + color.green + "," + color.blue + "," + color.alpha
        + "|" + (text == null ? "-" : text.red + "," + text.green + "," + text.blue + "," + text.alpha) + "|" + style.visible + "|" + style.zIndex
        + "|" + node.layout.text + "|" + node.children.length + "|");
      var bounds = node.resolved == null ? null : node.globalBounds();
      out.add(bounds == null ? "-" : bounds.x + "," + bounds.y + "," + bounds.width + "," + bounds.height);
      out.add("\n");
    });
    return out.toString();
  }

  /** The node of a control that restyles itself, by its key. */
  static function control(root:RenderNode, key:String):RenderNode {
    var found:Null<RenderNode> = null;
    root.walk(function(node) {
      if (node.styleKey == key && (node.styleType == "button" || node.styleType == "checkbox" || node.styleType == "toggle"
        || node.styleType == "radio")) found = node;
    });
    check(found != null, "No control " + key);
    return cast found;
  }

  static function center(root:RenderNode, key:String):{x:Float, y:Float} {
    var bounds = control(root, key).globalBounds();
    return {x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2};
  }

  /**
   * Drives both rigs through `script`, requiring the patched tree to match the full rebuild after every frame.
   * `rebuilds` is how many times the retained panel may build in the patched rig: once, plus once per step that changes what it shows.
   */
  static function run(fonts:FontCollection, name:String, scrolling:Bool, controls:Bool, rebuilds:Int, script:Array<{action:String, key:String}>):Void {
    var patched = new Rig(fonts, true, scrolling, controls), reference = new Rig(fonts, false, scrolling, controls);
    var patchedRoot = patched.submit(), referenceRoot = reference.submit();
    check(signature(patchedRoot) == signature(referenceRoot), "The first frames differ");
    var changed = 0, waitsChanged = 0;
    for (index in 0...script.length) {
      var step = script[index];
      var before = signature(patchedRoot);
      var buildsBefore = patched.panelBuilds;
      for (rig in [patched, reference]) {
        var at = center(rig == patched ? patchedRoot : referenceRoot, step.key);
        switch step.action {
          case "move": rig.ui.pointerMove(at.x, at.y);
          case "down": rig.ui.pointerDown(at.x, at.y, 0);
          case "up": rig.ui.pointerUp(at.x, at.y, 0);
          // Released away from the control it was pressed on: nothing activates.
          case "release": rig.ui.pointerUp(-20.0, -20.0, 0);
          case "wait":
          default: rig.ui.pointerMove(-20.0, -20.0);
        }
        var root = rig.submit();
        if (rig == patched) patchedRoot = root; else referenceRoot = root;
      }
      check(signature(patchedRoot) == signature(referenceRoot),
        "Step " + index + " (" + step.action + " " + step.key + ") differs from the full rebuild:\n--- patched\n" + signature(patchedRoot)
        + "--- reference\n" + signature(referenceRoot));
      if (signature(patchedRoot) != before) {
        changed++;
        if (step.action == "wait") waitsChanged++;
      }
      if (Sys.args().indexOf("--trace") >= 0) Sys.println(step.action + " " + step.key + ": panel builds +" + (patched.panelBuilds - buildsBefore));
    }
    check(changed >= 6, name + ": pointer changes did not restyle anything (" + changed + ")");
    if (scrolling) check(waitsChanged >= 3, "The scrollbar did not fade frame by frame (" + waitsChanged + ")");
    check(patched.clicks == reference.clicks, "Clicks differ: " + patched.clicks + " vs " + reference.clicks);
    check(patched.checked == reference.checked && patched.toggled == reference.toggled && patched.chosen == reference.chosen,
      name + ": activations differ from the full rebuild");
    for (index in 0...patched.decorated.length) {
      var key = patched.decorated[index].key;
      check(patched.decorated[index].presses == reference.decorated[index].presses,
        "A listener added after build was lost on " + key + ": " + patched.decorated[index].presses + " vs " + reference.decorated[index].presses);
      var decoratedNode = control(patchedRoot, key);
      check(decoratedNode.layout.style.zIndex == 3, "A style change made after build was lost on " + key);
      var overlays = 0;
      decoratedNode.walk(function(node) { if (node.layout.style.width.value == 5.5 && node.layout.style.height.value == 7.5) overlays++; });
      check(overlays == 1, "A child added after build was lost or duplicated on " + key + " (" + overlays + ")");
    }
    check(patched.panelBuilds == rebuilds, name + ": the retained panel built " + patched.panelBuilds + " times, expected " + rebuilds);
    check(reference.panelBuilds > patched.panelBuilds, name + ": the reference did not rebuild the panel");
    Sys.println("PASS " + name + ": " + script.length + " steps match a full rebuild (" + changed + " changed the tree); panel builds patched="
      + patched.panelBuilds + " reference=" + reference.panelBuilds);
    patched.ui.dispose(); reference.ui.dispose();
  }


  static function find(root:RenderNode, text:String):Null<RenderNode> {
    var found:Null<RenderNode> = null;
    root.walk(function(node) { if (node.layout.text == text) found = node; });
    return found;
  }

  /**
   * One rebuild of a self-updating widget, applied to the node it built before: the node stays with what its caller attached,
   * takes the callbacks, style and children of the new build, and is only replaced when its kind changes.
   */
  static function reconcile(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts);
    var gauge = new Gauge(), decorated = new DecoratedGauge(gauge);
    var frame = new LayoutFrame(240.0, 120.0);
    // Retained, so that only the gauge itself builds again.
    var view:View = new RetainedView("gauge-panel", function(_) return new Column("gauge-column", [new KeyedView("gauge", decorated)]));
    var submit = function() return ui.submitCached(function() return view, frame, "gauge");
    var column = submit();
    var root = column.children[0];
    var semantics = root.semantics;
    check(find(root, "level 1") != null && gauge.builds == 1, "The gauge did not build");
    for (level in 2...4) {
      gauge.level = level;
      check(ui.buildContext.requestPatch(cast gauge.id), "The gauge was not registered as self-updating");
      var next = submit().children[0];
      check(next == root && RenderNode.latest(root) == root, "A rebuild replaced the node instead of reconciling it");
      check(gauge.builds == level, "The gauge built " + gauge.builds + " times");
      check(find(root, "level " + level) != null && find(root, "level " + (level - 1)) == null, "The builder's child was not replaced");
      check(root.layout.style.zIndex == level, "The builder's style change was not applied");
      check(root.layout.style.positionX == 4.0, "The caller's style change was lost");
      check(root.semantics == semantics, "Semantics the caller replaced were taken back");
      var callerChildren = 0;
      for (child in root.children) if (child.styleType == null && child.layout.visualKind == LayoutVisualKind.Box) callerChildren++;
      check(callerChildren == 1 && root.children.length == 2, "A child added by the caller was lost or duplicated");
      var bounds = root.globalBounds();
      ui.pointerDown(bounds.x + 5, bounds.y + 5, 0);
      ui.pointerUp(bounds.x + 5, bounds.y + 5, 0);
      check(gauge.clicked == "level " + level, "The listener of the first build ran instead of the new one: " + gauge.clicked);
      check(decorated.presses == level - 1, "The caller's listener ran " + decorated.presses + " times");
      var paint:Array<Dynamic> = Reflect.field(root, "paintHandlers");
      check(paint != null && paint.length == 1, "The paint callbacks were not replaced one for one");
      var paintGauge:Dynamic = paint[0];
      paintGauge(null, null);
      check(gauge.painted == "level " + level, "The paint callback of the first build ran instead of the new one: " + gauge.painted);
    }
    // A build that changes the node's kind cannot be reconciled: its node is replaced.
    gauge.asText = true;
    check(ui.buildContext.requestPatch(cast gauge.id), "The gauge was not registered as self-updating");
    var replaced = submit().children[0];
    check(replaced != root && RenderNode.latest(root) == replaced, "A change of kind did not replace the node");
    check(ui.buildContext.requestPatch(cast gauge.id), "The replacement was not registered as self-updating");
    ui.dispose();
    Sys.println("PASS reconcile: a rebuild keeps the node and what callers added, takes the new build's style, children, listeners and paint, and is replaced only when its kind changes");
    textField(fonts);
  }

  static function paintTrace(node:RenderNode):PaintTrace {
    var trace = new PaintTrace();
    var handlers:Array<Dynamic> = Reflect.field(node, "paintHandlers");
    check(handlers != null && handlers.length == 2, "Builder or caller paint was lost or duplicated");
    for (handler in handlers) {
      var paint:Canvas->ResolvedLayoutItem->Void = cast handler;
      paint(trace, cast node.resolved);
    }
    return trace;
  }

  /** Repeated drag callbacks use live geometry; both controls keep caller additions while their paint matches a rebuild. */
  static function motion(fonts:FontCollection):Void {
    var patched = new MotionRig(fonts, true), reference = new MotionRig(fonts, false);
    var left = patched.submit(), right = reference.submit();
    var slider = left.children[0], progress = left.children[1];
    var overlaySlider = slider.children[0], overlayProgress = progress.children[0];
    var previousPaint = paintTrace(progress), animatedSteps = 0, steps = 0;
    var compare = function() {
      left = patched.submit(); right = reference.submit(); steps++;
      check(left.children[0] == slider && left.children[1] == progress, "A motion control was replaced");
      check(RenderNode.latest(cast patched.sliderBuilt) == slider && RenderNode.latest(cast patched.progressBuilt) == progress,
        "A build root did not resolve to the live node");
      check(slider.children[0] == overlaySlider && progress.children[0] == overlayProgress,
        "The caller's child was replaced");
      check(signature(left) == signature(right), "Motion step " + steps + " differs from a full rebuild");
      check(patched.slider.value == reference.slider.value, "Slider values differ after a drag");
      var sliderSemantics:Semantics = cast slider.semantics, otherSlider:Semantics = cast right.children[0].semantics;
      var progressSemantics:Semantics = cast progress.semantics, otherProgress:Semantics = cast right.children[1].semantics;
      check(Semantics.same(sliderSemantics, otherSlider) &&
        Semantics.same(progressSemantics, otherProgress), "Motion semantics differ at step " + steps
          + ": slider=" + sliderSemantics.value + "/" + otherSlider.value
          + " progress=" + progressSemantics.value + "/" + otherProgress.value
          + " targets=" + patched.progress.value + "/" + reference.progress.value);
      check(paintTrace(slider).same(paintTrace(right.children[0])), "Slider paint differs at step " + steps);
      var painted = paintTrace(progress);
      check(painted.same(paintTrace(right.children[1])), "Progress paint differs at step " + steps);
      if (!painted.same(previousPaint)) animatedSteps++;
      previousPaint = painted;
      for (node in [slider, progress])
        check(node.layout.style.zIndex == 3 && node.layout.style.width.value == 180.0 && node.children.length == 1,
          "Caller style or children were lost or duplicated");
      for (index in 0...2)
        check(patched.decorated[index].presses == reference.decorated[index].presses, "Caller listeners differ");
    };
    for (fraction in [0.1, 0.3, 0.7, 0.95, 0.2, 0.6]) {
      for (rig in [patched, reference]) {
        var node = rig == patched ? slider : right.children[0];
        var bounds = node.globalBounds();
        var x = bounds.x + 10.0 + fraction * (bounds.width - 20.0), y = bounds.y + bounds.height * 0.5;
        if (fraction == 0.1) rig.ui.pointerDown(x, y, 0);
        else rig.ui.pointerMove(x, y);
      }
      compare();
      check(Math.abs(patched.slider.value - fraction) < 0.000001, "The drag stopped using live geometry");
    }
    for (rig in [patched, reference]) rig.ui.pointerUp(-10.0, -10.0, 0);
    compare();
    for (key in [UiKey.Right, UiKey.End, UiKey.Home]) {
      patched.ui.key(UiEventKind.KeyDown, key); reference.ui.key(UiEventKind.KeyDown, key); compare();
    }
    for (value in [0.2, 0.6, 0.9, 0.1, 1.0]) {
      patched.progress.value = reference.progress.value = value;
      check(patched.ui.buildContext.requestPatch(progress.id), "Progress was not registered as self-updating");
      for (_ in 0...4) compare();
    }
    for (rig in [patched, reference]) {
      var bounds = (rig == patched ? progress : right.children[1]).globalBounds();
      rig.ui.pointerDown(bounds.x + bounds.width * 0.5, bounds.y + bounds.height * 0.5, 0);
    }
    compare();
    for (rig in [patched, reference]) rig.ui.pointerUp(-10.0, -10.0, 0);
    compare();
    check(patched.decorated[0].presses > 0 && patched.decorated[1].presses > 0, "Caller listeners never ran");
    check(animatedSteps >= 10, "Progress paint did not advance through the animation");
    check(patched.panelBuilds == 1 && reference.panelBuilds > steps, "Motion rebuilt its retained panel");
    patched.ui.dispose(); reference.ui.dispose();
    Sys.println("PASS motion: " + steps + " decorated slider/progress steps keep nodes, caller additions and match rebuilt geometry, semantics and paint");
  }

  /** A text field patches itself while typing: its node stays, with what its caller attached, and matches a full rebuild. */
  static function textField(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts);
    var field = new TextField("name", "abc");
    var presses = 0;
    var decorated = new FieldDecoration(field, function() presses++);
    var view:View = new RetainedView("field-panel", function(_) return decorated);
    var frame = new LayoutFrame(240.0, 60.0);
    var build = function() return view;
    var submit = function() return ui.submitCached(build, frame, "field");
    var root = submit();
    check(ui.focusWidget(root.id), "The field did not take focus");
    root = submit();
    var node = root;
    for (letter in ["d", "e", "f"]) {
      ui.text(UiEventKind.TextInput, letter);
      root = submit();
      check(root == node, "Typing replaced the field's node");
      check(ui.verifyRetention(build, frame) == null, "The patched field differs from a fresh build");
      // The verification built everything afresh, so the next frame starts from a new node.
      root = submit();
      node = root;
    }
    var typed:Null<RenderNode> = null;
    root.walk(function(child) { if (child.layout.text != null && child.layout.text.length == 6) typed = child; });
    check(typed != null, "The typed text is not shown");
    var bounds = root.globalBounds();
    ui.pointerDown(bounds.x + 2, bounds.y + 2, 0);
    ui.pointerUp(bounds.x + 2, bounds.y + 2, 0);
    check(presses == 1, "The caller's listener ran " + presses + " times, expected 1");
    ui.dispose();
    Sys.println("PASS field: typing patches the field in place, keeping what its caller attached");
  }

  static function buildFeedbackFocus(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), frame = new LayoutFrame(240, 120);
    ui.verifyRetentionEvery = 1;
    var revealed = false, target = 0;
    var view:View = new DecoratedControl("feedback-focus", context -> {
      var root = new RenderNode(context.id("feedback-root"), LayoutVisualKind.Box);
      var id = context.id("late-target");
      target = id.value;
      if (revealed) {
        var style = new LayoutStyle();
        style.width = LayoutAxis.fixed(20); style.height = LayoutAxis.fixed(20);
        var child = new RenderNode(id, LayoutVisualKind.Box, style);
        child.focusable = true;
        child.states = context.interactionStates.get(id);
        root.add(child);
      } else {
        context.requestFocusAfterLayout(id);
        root.onResolved(_ -> {
          revealed = true;
          context.requestBuildFeedback();
        });
      }
      return root;
    });
    ui.submitCached(() -> view, frame, "feedback-focus");
    var focused = ui.focus.focusedId;
    check(focused != null && focused.value == target, "Build feedback consumed deferred focus before its target was built");
    check(ui.verifyRetention(() -> view, frame) == null, "Focus after build feedback differs from a fresh build");
    ui.dispose();
    Sys.println("PASS feedback: deferred focus waits until resolved build feedback has materialized its target");
  }

  static function resolvedList(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), frame = new LayoutFrame(240, 600);
    ui.buildContext.environment.reducedMotion = true;
    ui.verifyRetentionEvery = 1;
    var controller = new ScrollController(), height = 480, selected = -1, notifications = 0;
    var fractional = false;
    var view:View = new RetainedView("resolved-list", context -> {
      var style = new LayoutStyle();
      style.width = LayoutAxis.grow();
      var requested = context.observeInt(() -> height);
      style.height = LayoutAxis.fixed(context.observeBool(() -> fractional) ? requested / 3.14159 : requested);
      var list = new haxeon.ui.widgets.collections.ListView("rows", new WindowItems(), style, controller, 300);
      list.selectionProvider = () -> selected;
      list.onSelectionChanged = index -> {selected = index; notifications++;};
      return list;
    });
    var build = () -> view;
    for (nextHeight in [480, 137, 341, 1, 480]) {
      height = nextHeight;
      ui.submitCached(build, frame, "list-height-" + height);
      check(controller.viewportHeight == height, "List did not settle its resolved height: actual=" + controller.viewportHeight + " requested=" + height);
      check(ui.verifyRetention(build, frame) == null, "Resolved list window differs from a fresh build");
    }
    fractional = true;
    ui.submitCached(build, frame, "fractional-list");
    check(controller.viewportHeight > 0 && ui.verifyRetention(build, frame) == null, "Fractional list viewport did not settle");
    fractional = false;
    ui.submitCached(build, frame, "list-height-480");
    controller.jumpTo(0, 240);
    var scrolled = ui.submitCached(build, frame, "list-height-480"), found = false;
    scrolled.walk(node -> {if (node.layout.text == "row-30") found = true;});
    check(found, "A retained list did not materialize the newly scrolled window");
    controller.jumpTo(0, 0);
    ui.submitCached(build, frame, "list-height-480");
    for (next in [8, -1, 1000, 3]) {
      selected = next;
      var root = ui.submitCached(build, frame, "list-selection-" + selected), count = 0;
      root.walk(node -> {
        if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem &&
          (node.semantics.states & haxeon.ui.semantics.AccessibilityState.Selected) != 0) count++;
      });
      check(count == (selected < 0 || selected >= 40 ? 0 : 1), "Controlled list selection is stale");
      check(notifications == 0, "External list selection notified its owner");
    }
    var root = ui.root;
    if (root == null) throw "Missing controlled list";
    var row:Null<RenderNode> = null;
    root.walk(node -> {
      if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem && node.semantics.positionInSet == 1) row = node;
    });
    var target = row;
    if (target == null) throw "Missing first list row";
    var bounds = target.globalBounds();
    ui.pointerDown(bounds.x + 10, bounds.y + 10, 0);
    ui.pointerUp(bounds.x + 10, bounds.y + 10, 0);
    ui.submitCached(build, frame, "list-input");
    check(selected == 0 && notifications == 1, "Controlled list input did not notify its owner exactly once");
    check(ui.verifyRetention(build, frame) == null, "Controlled list input differs from a fresh build");
    ui.dispose();
    Sys.println("PASS list: resolved windows settle before publication through grow, shrink and a one-pixel viewport; controlled selection matches fresh builds");
  }

  static function verifyDisabledFocus(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), frame = new LayoutFrame(240, 120), enabled = true;
    ui.verifyRetentionEvery = 1;
    var view:View = new RetainedView("focus-disabling", context -> {
      var button = new Button("Focus", null, () -> {});
      button.enabled = context.observeBool(() -> enabled);
      return button;
    });
    var build = () -> view;
    var root = ui.submitCached(build, frame, "focus-initial");
    ui.focusWidget(root.id);
    ui.submitCached(build, frame, "focus-settled");
    enabled = false;
    root = ui.submitCached(build, frame, "focus-disabled");
    check(!root.enabled && ui.focus.focusedId == null, "Disabling a retained focus target did not clear focus");
    check(ui.verifyRetention(build, frame) == null, "A committed focus pass differs from a full rebuild");
    ui.dispose();
    Sys.println("PASS verification: a focus pass compares against its committed nodes, including fresh disabled controls");
  }

  static function verifyPointerFlags(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), frame = new LayoutFrame(240, 120);
    var flags:Int = haxeon.ui.style.StyleState.Checked;
    var label = "hovered pressed";
    var view:View = new RetainedView("flag-verification", _ -> new DecoratedControl("flags", context -> {
      var node = new RenderNode(context.id("flags"), LayoutVisualKind.Box);
      node.states = flags;
      node.semantics = new Semantics(AccessibilityRole.Checkbox, label);
      return node;
    }));
    var build = () -> view;
    var root = ui.submitCached(build, frame, "flags");
    // Routing may add pointer flags to a node that did not build from them. Checked still has to compare.
    root.states |= haxeon.ui.style.StyleState.Hovered | haxeon.ui.style.StyleState.Pressed;
    check(ui.verifyRetention(build, frame) == null, "Pointer normalization corrupted combined checked flags");
    flags = 0;
    check(ui.verifyRetention(build, frame) != null, "Pointer normalization hid a checked-state mismatch");
    label = "pressed hovered";
    check(ui.verifyRetention(build, frame) != null, "Pointer normalization hid hovered/pressed words in a label");
    ui.dispose();
    Sys.println("PASS verification: only pointer flag bits are ignored; checked flags and label text still compare");
  }

  /** Verify mode must pass with an honest cache key and catch one that misses an input. */
  static function verifyMode(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    var frame = new LayoutFrame(240.0, 120.0);
    var label = "first";
    var honest = true;
    var view:View = new RetainedView("labelled", function(_) return new haxeon.ui.widgets.text.Text(label),
      function() return honest ? label : "always the same");
    var build = function() return view;
    ui.submitCached(build, frame, "verify");
    check(ui.verifyRetention(build, frame) == null, "An honest cache failed verification");
    label = "second";
    ui.submitCached(build, frame, "verify-2");
    check(ui.verifyRetention(build, frame) == null, "An honest cache failed verification after a change");
    honest = false;
    ui.submitCached(build, frame, "verify-3");
    label = "third";
    ui.submitCached(build, frame, "verify-4");
    var difference = ui.verifyRetention(build, frame);
    check(difference != null && difference.indexOf("third") >= 0,
      "Verification missed a cache whose key leaves out what it shows: " + difference);
    // The automatic mode reports through the callback.
    var reported:Null<String> = null;
    ui.onRetentionMismatch = function(text) reported = text;
    ui.verifyRetentionEvery = 1;
    label = "fourth";
    ui.submitCached(build, frame, "verify-5");
    check(reported != null, "The automatic check did not report a stale cache");
    ui.dispose();
    Sys.println("PASS verify: an honest cache passes; a key missing an input is reported, also by the automatic check");
    observedReads(fonts);
  }

  /** A retained view without a key follows what its builder read through observeString, and nothing else rebuilds it. */
  static function observedReads(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts);
    var frame = new LayoutFrame(240.0, 120.0);
    var title = "first", builds = 0, frameNumber = 0;
    var inner:View = new RetainedView("inner", function(context) {
      builds++;
      return new haxeon.ui.widgets.text.Text(context.observeString(function() return title));
    });
    // An outer retained view around the inner one must notice the inner read too.
    var view:View = new RetainedView("outer", function(_) return inner);
    var build = function() return view;
    var shown = function():String {
      var found = "";
      ui.submitCached(build, frame, "observed-" + (frameNumber++)).walk(function(node) { if (node.layout.text != null) found = node.layout.text; });
      return found;
    };
    check(shown() == "first" && builds == 1, "The first build did not show the observed value");
    check(shown() == "first" && builds == 1, "An unchanged observed read rebuilt the view");
    title = "second";
    check(shown() == "second" && builds == 2, "A changed observed read was not picked up through the outer cache");
    check(ui.verifyRetention(build, frame) == null, "Observed reads left the retained tree stale");
    ui.dispose();
    Sys.println("PASS observed: a keyless retained view rebuilds exactly when an observed read changes, through an outer cache");
    unannouncedEdits(fonts);
  }

  /** With verification on, a node of the submitted tree changed between frames must be announced with willEditRetained. */
  static function unannouncedEdits(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts);
    var frame = new LayoutFrame(240.0, 120.0);
    var view:View = new RetainedView("edited", function(_) return new haxeon.ui.widgets.text.Text("label"), function() return "fixed");
    var build = function() return view;
    var reported:Null<String> = null;
    ui.onRetentionMismatch = function(text) reported = text;
    ui.verifyRetentionEvery = 1000;
    var frameNumber = 0;
    var submit = function() return ui.submitCached(build, frame, "edits-" + (frameNumber++));
    var text:Null<RenderNode> = null;
    submit().walk(function(node) { if (node.layout.text == "label") text = node; });
    check(text != null, "No text node");
    var node:RenderNode = cast text;
    node.layout.style.positionX = 7.0;
    submit();
    check(reported != null && reported.indexOf("without willEditRetained") >= 0, "An unannounced edit was not reported: " + reported);
    reported = null;
    ui.buildContext.willEditRetained(node);
    node.layout.style.positionX = 9.0;
    submit();
    check(reported == null, "An announced edit was reported: " + reported);
    ui.dispose();
    Sys.println("PASS edits: a change to the submitted tree is reported unless announced with willEditRetained");
  }

  /**
   * Equality of text styles, paragraph styles, rectangles, shortcuts and effect parameters is generated from their fields, and
   * the hand-written comparisons and keys that remain must name every field: adding one to a class fails here until they do.
   */
  static function structuralValues():Void {
    var text = new TextStyle(14.0), changedText = haxeon.Structural.copy(text);
    check(haxeon.Equality.equals(text, changedText) && haxeon.Structural.changedMask(text, changedText) == 0, "TextStyle.copy is not equal");
    changedText.letterSpacing = 0.5;
    check(!haxeon.Equality.equals(text, changedText), "TextStyle equality ignores letter spacing");
    var paragraph = new ParagraphStyle(), changedParagraph = haxeon.Structural.copy(paragraph);
    changedParagraph.tabWidth = 4;
    check(!haxeon.Equality.equals(paragraph, changedParagraph), "ParagraphStyle equality ignores the tab width");
    changedParagraph = haxeon.Structural.copy(paragraph);
    changedParagraph.lineHeight = 20.0;
    check(!haxeon.Equality.equals(paragraph, changedParagraph), "ParagraphStyle equality ignores the line height");
    check(haxeon.Structural.changedMask(paragraph, changedParagraph) == haxeon.Structural.fieldBit(ParagraphStyle, "lineHeight"),
      "ParagraphStyle reports a changed line height as another field");

    check(haxeon.Equality.equals(new haxeon.ui.Rect(1.0, 2.0, 3.0, 4.0), new haxeon.ui.Rect(1.0, 2.0, 3.0, 4.0))
      && !haxeon.Equality.equals(new haxeon.ui.Rect(1.0, 2.0, 3.0, 4.0), new haxeon.ui.Rect(1.0, 2.0, 3.0, 5.0)), "Rect equality is wrong");
    check(new haxeon.ui.core.Shortcut(65, 2).equals(new haxeon.ui.core.Shortcut(65, 2))
      && !new haxeon.ui.core.Shortcut(65, 2).equals(new haxeon.ui.core.Shortcut(65, 4)) && !new haxeon.ui.core.Shortcut(65, 2).equals(null),
      "Shortcut equality is wrong");
    check(haxeon.ui.style.EffectParameter.vec2(1.0, 2.0).isEqual(haxeon.ui.style.EffectParameter.vec2(1.0, 2.0))
      && !haxeon.ui.style.EffectParameter.vec2(1.0, 2.0).isEqual(haxeon.ui.style.EffectParameter.vec2(1.0, 3.0))
      && !haxeon.ui.style.EffectParameter.scalar(1.0).isEqual(haxeon.ui.style.EffectParameter.vec2(1.0, 0.0)),
      "EffectParameter equality is wrong");

    check(new haxeon.ui.style.InkOverflow(1.0, 2.0, 3.0, 4.0).isEqual(new haxeon.ui.style.InkOverflow(1.0, 2.0, 3.0, 4.0))
      && !new haxeon.ui.style.InkOverflow(1.0, 2.0, 3.0, 4.0).isEqual(new haxeon.ui.style.InkOverflow(1.0, 2.0, 3.0, 5.0)),
      "InkOverflow equality is wrong");
    var definition = function(id:Int, overflow:Float, types:Array<haxeon.ui.style.EffectParameterType>)
      return new haxeon.ui.style.CustomEffectDefinition(id, "effect", types, new haxeon.ui.style.InkOverflow(overflow, 0.0, 0.0, 0.0));
    check(definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Float]).isEqual(definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Float]))
      && !definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Float]).isEqual(definition(2, 1.0, [haxeon.ui.style.EffectParameterType.Float]))
      && !definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Float]).isEqual(definition(1, 2.0, [haxeon.ui.style.EffectParameterType.Float]))
      && !definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Float]).isEqual(definition(1, 1.0, [haxeon.ui.style.EffectParameterType.Vec2])),
      "CustomEffectDefinition equality is wrong");
    check(haxeon.ui.style.StyleResolver.valueKeysComplete(), "A Color, LayoutAxis, Insets or Transform2D field is missing from the style cache's value keys");
    semanticsFields();
    Sys.println("PASS values: text, paragraph, rectangle, shortcut and effect parameter equality is generated; hand-written keys and Semantics.same name every field");
  }

  /** Semantics.same is written by hand (its value compares through sameValue); changing any other field in turn must show. */
  static function semanticsFields():Void {
    var base = new Semantics(AccessibilityRole.Button, "label", "value");
    // A deferred value's source and revision are compared through sameValue, not as fields of their own.
    var notCompared = ["valueSource", "valueRevision"], compared = 0;
    check(Semantics.same(base, new Semantics(AccessibilityRole.Button, "label", "value")), "Equal semantics differ");
    for (name in Reflect.fields(base)) {
      if (notCompared.indexOf(name) >= 0) continue;
      var changed = new Semantics(AccessibilityRole.Button, "label", "value");
      var current:Dynamic = Reflect.field(changed, name), next:Dynamic;
      if (Std.isOfType(current, String)) next = current + "!";
      else if (Std.isOfType(current, Bool)) next = !current;
      else if (Std.isOfType(current, Int)) next = current + 1;
      else if (Std.isOfType(current, Float)) next = current + 1.0;
      else throw "Semantics gained the field " + name + " of a type this test cannot change; extend it, and Semantics.same";
      Reflect.setField(changed, name, next);
      check(!Semantics.same(base, changed), "Semantics.same ignores " + name);
      compared++;
    }
    check(compared >= 20, "Semantics fields were not found by reflection (" + compared + ")");
  }

  /** A build reparents a cached subtree; its old membership and topology must still compare as the submitted frame. */
  static function submittedIndex(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), builds = 0;
    var retained = new RetainedView("membership", function(_) {
      builds++;
      return new Text("kept child");
    });
    var frame = new LayoutFrame(240, 160);
    var build = function() return new Column("membership-host", [
      new KeyedView("kept", retained), new KeyedView("other", new Text("other child"))]);
    var first = ui.submit(build(), frame), child = first.children[0];
    for (index in 0...4) {
      var next = ui.submit(build(), frame), metrics = ui.frameMetrics;
      check(next != first && next.children[0] == child && builds == 1, "The membership fixture did not reparent a retained child");
      check(metrics != null && metrics.styleChangedNodes == 0 && metrics.nativeLayoutReused,
        "Reparenting while rebuilding treated unchanged nodes as new inputs or changed topology");
    }
    var reordered = function() return new Column("membership-host", [
      new KeyedView("other", new Text("other child")), new KeyedView("kept", retained)]);
    var moved = ui.submit(reordered(), frame), metrics = ui.frameMetrics;
    check(moved.children[1] == child && metrics != null && metrics.nativeLayoutSubmitted && metrics.styleChangedNodes == 0,
      "An actual child reordering was lost or invalidated unchanged styles");
    check(ui.verifyRetention(reordered, frame) == null, "Reordered retained children differ from a full build");
    ui.dispose();
    Sys.println("PASS membership: rebuilding reparents retained nodes without false input changes; a real reordering still submits and verifies");
  }

  static function tabsAndPopup(fonts:FontCollection):Void {
    var patched = new TabsRig(fonts, true), reference = new TabsRig(fonts, false);
    var root = patched.submit(); reference.submit();
    var caller = root.children[root.children.length - 1], steps = 0;
    function compareTabs():Void {
      var left = patched.submit(), right = reference.submit();
      steps++;
      check(left == root && left.children.indexOf(caller) >= 0 && left.layout.style.zIndex == 3,
        "Tabs lost their root or caller additions at step " + steps);
      check(signature(left) == signature(right), "Tabs differ from a full rebuild at step " + steps);
      check(patched.tabs.selectedKey == reference.tabs.selectedKey && patched.changes == reference.changes
        && patched.closes == reference.closes && patched.decorated.presses == reference.decorated.presses,
        "Tab callbacks or selection differ at step " + steps);
    }
    for (name in ["second", "first", "second"]) {
      for (rig in [patched, reference]) {
        var current = rig.ui.root;
        if (current == null) throw "Missing tabs";
        var target = control(current, name), bounds = target.globalBounds();
        rig.ui.pointerMove(bounds.x + 10, bounds.y + bounds.height / 2);
      }
      compareTabs();
      for (rig in [patched, reference]) {
        var current = rig.ui.root;
        if (current == null) throw "Missing tabs";
        var bounds = control(current, name).globalBounds();
        rig.ui.pointerDown(bounds.x + 10, bounds.y + bounds.height / 2, 0);
        rig.ui.pointerUp(bounds.x + 10, bounds.y + bounds.height / 2, 0);
      }
      compareTabs();
    }
    for (key in [UiKey.Right, UiKey.Left, UiKey.Right]) {
      for (rig in [patched, reference]) {rig.ui.key(UiEventKind.KeyDown, key); rig.ui.key(UiEventKind.KeyUp, key);}
      compareTabs();
    }
    check(patched.panelBuilds == 1, "Local tabs rebuilt their enclosing panel");
    check(patched.decorated.presses > 0, "Tabs did not invoke the caller listener");
    patched.ui.dispose(); reference.ui.dispose();

    var popup = new PopupRig(fonts, true), rebuilt = new PopupRig(fonts, false);
    popup.submit(); rebuilt.submit();
    var node = popup.menu().node, added = popup.caller, popupSteps = 0;
    function comparePopup():Void {
      var left = popup.submit(), right = rebuilt.submit();
      popupSteps++;
      check(popup.menu().node == node && node.children.indexOf(cast added) >= 0 && node.layout.style.zIndex == 11,
        "Popup lost its root or caller additions at step " + popupSteps);
      check(signature(left) == signature(right), "Popup differs from a full rebuild at step " + popupSteps
        + ":\n--- patched\n" + signature(left) + "--- reference\n" + signature(right));
      check(paintTrace(node).same(paintTrace(rebuilt.menu().node)), "Popup caller paint differs at step " + popupSteps);
      check(popup.active == rebuilt.active && popup.chosen == rebuilt.chosen && popup.selections == rebuilt.selections
        && popup.closes == rebuilt.closes && popup.presses == rebuilt.presses, "Popup callbacks differ at step " + popupSteps);
    }
    for (rig in [popup, rebuilt]) rig.ui.focusWidget(rig.menu().optionNodes[0].id);
    comparePopup();
    for (key in [UiKey.Down, UiKey.Down, UiKey.Down, UiKey.End, UiKey.Up, UiKey.Home]) {
      for (rig in [popup, rebuilt]) {rig.ui.key(UiEventKind.KeyDown, key); rig.ui.key(UiEventKind.KeyUp, key);}
      comparePopup();
    }
    for (rig in [popup, rebuilt]) {
      var option = rig.menu().optionNodes[4], resolved = option.resolved;
      if (resolved == null) throw "Missing popup option geometry";
      var bounds = resolved.clippedViewportBounds();
      rig.ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
      rig.ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    }
    comparePopup();
    check(popup.chosen == 4 && popup.selections == 1, "Popup did not select exactly once");
    check(popup.presses > 0, "Popup did not invoke the caller listener");
    for (rig in [popup, rebuilt]) {
      var bounds = rig.menu().node.globalBounds();
      rig.ui.scroll(bounds.x + 5, bounds.y + bounds.height / 2, 0, 60);
    }
    comparePopup();
    check(popup.backgroundWheels == 0 && rebuilt.backgroundWheels == 0, "Popup wheel input reached its enclosing view");
    for (rig in [popup, rebuilt]) rig.ui.key(UiEventKind.KeyDown, UiKey.Escape);
    comparePopup();
    check(popup.panelBuilds == 1, "Popup navigation rebuilt its enclosing panel");
    popup.ui.dispose(); rebuilt.ui.dispose();
    Sys.println("PASS tabs/popup: switching retained tabs and navigating, selecting and scrolling a popup keep roots and caller additions and match fresh builds");
  }

  static function editedComposite(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), gauge = new Gauge();
    var view:View = new RetainedView("edited-composite", _ -> gauge), frame = new LayoutFrame(200, 100);
    var build = () -> view;
    ui.submitCached(build, frame, "edited-composite");
    var label = gauge.labelNode;
    if (label == null) throw "Missing composite child";
    gauge.offset = 20;
    ui.buildContext.willEditRetained(label);
    label.layout.style.transform = haxeon.ui.Transform2D.identity().translated(0, -gauge.offset);
    check(ui.buildContext.requestPatch(cast gauge.id), "Composite updater was not registered");
    ui.submitCached(build, frame, "edited-composite");
    check(ui.verifyRetention(build, frame) == null, "Announced child edit was lost when its owner reconciled");
    ui.dispose();
    Sys.println("PASS editing: an announced child edit keeps its original native prior when its composite owner also patches");
  }

  static function updatingResources(fonts:FontCollection):Void {
    var ui = new UiContext(null, fonts), widget = new UpdatingResources(), caller = new UpdatingResources(), builds = 0;
    caller.enabled = true;
    var view:View = new RetainedView("resource-panel", _ -> {
      builds++;
      return new DecoratedControl("resource-host", context -> {
        var node = widget.build(context);
        node.add(context.withScope(new Key("caller"), () -> caller.build(context)));
        return node;
      });
    });
    var frame = new LayoutFrame(200, 100), key = "resources";
    var factories = 0;
    function submit():RenderNode return ui.submitCached(() -> {factories++; return view;}, frame, key);
    var root = submit();
    widget.enabled = true;
    check(ui.buildContext.requestPatch(cast widget.rootId), "Resource owner was not registered");
    submit();
    check(ui.buildContext.requestPatch(cast widget.rootId), "Composite owner was not rearmed");
    submit();
    check(ui.root != null && ui.root.children.length == 3 && ui.root.children[0].id.equals(cast widget.childId),
      "A newly materialized retained child displaced its caller decoration");
    key = "resources-next";
    submit();
    check(builds == 1 && widget.created == 1 && widget.disposed == 0, "Patched resources were not retained independently");
    widget.generation++;
    check(ui.buildContext.requestPatch(cast widget.childId), "Nested updater was not registered");
    submit();
    key = "resources-again";
    submit();
    check(builds == 1 && widget.created == 2 && widget.disposed == 1, "Replaced nested resources did not settle their lifetime");
    widget.reading++;
    key = "external-reading";
    var refreshed = submit();
    check(builds == 2 && refreshed.children[0].children[0].layout.text == "1:0:1", "Patched observed reads did not invalidate their enclosing cache");
    var value = widget.value;
    if (value == null) throw "Missing owned state";
    value.update(7);
    refreshed = submit();
    check(builds == 3 && refreshed.children[0].children[0].layout.text == "1:7:1", "Owned state revisions stopped invalidating retained caches");
    check(widget.value == value, "A live state handle changed across patches and complete builds");
    widget.enabled = false;
    key = "resources-remove";
    var previousFactories = factories;
    check(ui.buildContext.requestPatch(cast widget.rootId), "Resource owner was lost after a rebuild");
    submit();
    check(factories == previousFactories + 1, "A complete frame repeated its build to settle already tracked resource membership");
    check(widget.disposed == 2, "Removed child resources were not disposed");
    check(caller.created == 1 && caller.disposed == 0, "A caller-owned updater lost its resources across owner patches");
    ui.dispose();
    check(caller.created == caller.disposed, "A caller-owned updater leaked resources");
    check(widget.created == widget.disposed, "Composite updater leaked resources");
    Sys.println("PASS updating resources: nested patches retain current dependencies, replace and dispose resources, and invalidate on observed and widget-state changes");
  }

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    tabsAndPopup(fonts);
    editedComposite(fonts);
    updatingResources(fonts);
    verifyMode(fonts);
    verifyPointerFlags(fonts);
    verifyDisabledFocus(fonts);
    resolvedList(fonts);
    buildFeedbackFocus(fonts);
    reconcile(fonts);
    submittedIndex(fonts);
    motion(fonts);
    run(fonts, "buttons", false, false, 1, [
      {action: "move", key: "one"}, {action: "move", key: "two"}, {action: "move", key: "decorated"},
      {action: "down", key: "decorated"}, {action: "up", key: "decorated"}, {action: "move", key: "one"},
      {action: "down", key: "one"}, {action: "move", key: "two"}, {action: "up", key: "two"},
      {action: "move", key: "decorated"}, {action: "away", key: "one"}, {action: "move", key: "two"},
      {action: "down", key: "two"}, {action: "up", key: "two"},
    ]);
    // The scrollbar fades in on hover, waits, and fades out once the pointer leaves: every frame of it must match.
    var wait = {action: "wait", key: "one"};
    run(fonts, "scrolling", true, false, 1, [
      {action: "move", key: "one"}, wait, wait, wait, wait, {action: "move", key: "two"}, wait,
      {action: "down", key: "two"}, {action: "up", key: "two"}, wait,
      {action: "away", key: "one"}, wait, wait, wait, wait, wait, wait, wait, wait, wait,
      {action: "move", key: "one"}, wait, wait,
    ]);
    // Icon buttons, checkboxes, switches and radio options follow hover and press without rebuilding the panel. Pressing and
    // releasing elsewhere activates nothing; only the last click, on a checkbox, changes what the panel shows, so it builds twice.
    // The group's keyed options and the disabled option are covered as well.
    run(fonts, "controls", false, true, 2, [
      {action: "move", key: "icon"}, {action: "move", key: "check"}, {action: "move", key: "toggle"}, {action: "move", key: "radio"},
      {action: "move", key: "alpha"}, {action: "move", key: "beta"}, {action: "move", key: "disabled"}, {action: "move", key: "decorated-icon"},
      {action: "down", key: "decorated-icon"}, {action: "release", key: "decorated-icon"}, {action: "move", key: "decorated-check"},
      {action: "down", key: "decorated-check"}, {action: "release", key: "decorated-check"}, {action: "move", key: "decorated-radio"},
      {action: "down", key: "decorated-radio"}, {action: "release", key: "decorated-radio"},
      {action: "move", key: "check"}, {action: "down", key: "check"}, {action: "release", key: "check"},
      {action: "move", key: "toggle"}, {action: "down", key: "toggle"}, {action: "release", key: "toggle"},
      {action: "move", key: "beta"}, {action: "down", key: "beta"}, {action: "release", key: "beta"}, {action: "away", key: "icon"},
      {action: "move", key: "icon"}, {action: "down", key: "icon"}, {action: "up", key: "icon"}, {action: "move", key: "radio"},
      {action: "down", key: "radio"}, {action: "up", key: "radio"}, {action: "move", key: "decorated-icon"},
      {action: "down", key: "decorated-icon"}, {action: "up", key: "decorated-icon"}, {action: "move", key: "decorated-radio"},
      {action: "down", key: "decorated-radio"}, {action: "up", key: "decorated-radio"}, {action: "move", key: "decorated-check"},
      {action: "down", key: "decorated-check"}, {action: "up", key: "decorated-check"},
    ]);
    // The frame comparison and local style resolution name LayoutStyle fields by hand; each must name every one.
    check(RenderNode.styleFieldsClassified(), "A LayoutStyle field is in no invalidation group of the frame comparison");
    check(haxeon.ui.style.StyleResolver.localFieldsHandled == haxeon.Structural.allFieldsMask(LayoutStyle),
      "A LayoutStyle field has no style property in local style resolution");
    var style = new LayoutStyle();
    style.padding = new haxeon.ui.Insets(1.0, 2.0, 3.0, 4.0);
    var copied = style.copy();
    check(copied != style && haxeon.Equality.equals(copied, style) && haxeon.Structural.hash(copied) == haxeon.Structural.hash(style),
      "LayoutStyle.copy is not an equal copy");
    Sys.println("PASS structural: every LayoutStyle field is copied, compared, hashed, classified and resolved");
    structuralValues();
    fonts.dispose(); runtime.dispose();
    return 0;
  }
}
