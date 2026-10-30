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
    check(haxeon.ui.widgets.docking.DockWorkspace.labelKeyComplete(), "A TextStyle or ParagraphStyle field is missing from the tab label width key");
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

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    verifyMode(fonts);
    reconcile(fonts);
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
