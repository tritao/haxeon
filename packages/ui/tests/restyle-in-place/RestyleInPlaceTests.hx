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
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;

/** A button the way Tabs uses one: built, then given a listener and a style change by its caller. */
private class DecoratedButton implements View {
  public var presses = 0;

  public function new() {}

  public function build(context:BuildContext):RenderNode {
    var node = new Button("Decorated", null, null, "decorated").build(context);
    node.on(UiEventKind.PointerDown, function(_) presses++);
    node.layout.style.zIndex = 3;
    return node;
  }
}

/** One UI with a retained panel of buttons. */
private class Rig {
  public final ui:UiContext;
  public final frame:LayoutFrame = new LayoutFrame(240.0, 200.0);
  public final decorated = new DecoratedButton();
  public var panelBuilds = 0;
  public var clicks = 0;
  final view:View;

  /** `scrolling` puts the buttons in a scroll view that overflows, with motion on, so the scrollbar fades frame by frame. */
  public function new(fonts:FontCollection, restyleInPlace:Bool, scrolling:Bool = false) {
    ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = !scrolling;
    ui.buildContext.restyleInPlace = restyleInPlace;
    var rig = this;
    var panel = new RetainedView("panel", function(_) {
      rig.panelBuilds++;
      var column = new Column("column", [
        new KeyedView("one", new Button("One", null, function() rig.clicks++, "one")),
        new KeyedView("two", new Button("Two", null, function() rig.clicks++, "two")),
        new KeyedView("decorated", rig.decorated),
        new KeyedView("three", new Button("Three", null, function() rig.clicks++, "three")),
        new KeyedView("four", new Button("Four", null, function() rig.clicks++, "four")),
      ]);
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

  static function center(root:RenderNode, key:String):{x:Float, y:Float} {
    var found:Null<RenderNode> = null;
    root.walk(function(node) { if (node.styleType == "button" && node.styleKey == key) found = node; });
    check(found != null, "No button " + key);
    var bounds = found.globalBounds();
    return {x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2};
  }

  /** Drives both rigs through `script`, requiring the patched tree to match the full rebuild after every frame. */
  static function run(fonts:FontCollection, scrolling:Bool, script:Array<{action:String, key:String}>):Void {
    var patched = new Rig(fonts, true, scrolling), reference = new Rig(fonts, false, scrolling);
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
    var name = scrolling ? "scrolling" : "buttons";
    check(changed >= 6, name + ": pointer changes did not restyle anything (" + changed + ")");
    if (scrolling) check(waitsChanged >= 3, "The scrollbar did not fade frame by frame (" + waitsChanged + ")");
    check(patched.clicks == reference.clicks, "Clicks differ: " + patched.clicks + " vs " + reference.clicks);
    check(patched.decorated.presses == reference.decorated.presses,
      "A listener added after build was lost: " + patched.decorated.presses + " vs " + reference.decorated.presses);
    var decoratedNode:Null<RenderNode> = null;
    patchedRoot.walk(function(node) { if (node.styleKey == "decorated" && node.styleType == "button") decoratedNode = node; });
    check(decoratedNode != null && decoratedNode.layout.style.zIndex == 3, "A style change made after build was lost");
    check(patched.panelBuilds == 1, name + ": pointer changes rebuilt the retained panel " + patched.panelBuilds + " times");
    check(reference.panelBuilds > patched.panelBuilds, name + ": the reference did not rebuild the panel");
    Sys.println("PASS " + name + ": " + script.length + " steps match a full rebuild (" + changed + " changed the tree); panel builds patched="
      + patched.panelBuilds + " reference=" + reference.panelBuilds);
    patched.ui.dispose(); reference.ui.dispose();
  }

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    run(fonts, false, [
      {action: "move", key: "one"}, {action: "move", key: "two"}, {action: "move", key: "decorated"},
      {action: "down", key: "decorated"}, {action: "up", key: "decorated"}, {action: "move", key: "one"},
      {action: "down", key: "one"}, {action: "move", key: "two"}, {action: "up", key: "two"},
      {action: "move", key: "decorated"}, {action: "away", key: "one"}, {action: "move", key: "two"},
      {action: "down", key: "two"}, {action: "up", key: "two"},
    ]);
    // The scrollbar fades in on hover, waits, and fades out once the pointer leaves: every frame of it must match.
    var wait = {action: "wait", key: "one"};
    run(fonts, true, [
      {action: "move", key: "one"}, wait, wait, wait, wait, {action: "move", key: "two"}, wait,
      {action: "down", key: "two"}, {action: "up", key: "two"}, wait,
      {action: "away", key: "one"}, wait, wait, wait, wait, wait, wait, wait, wait, wait,
      {action: "move", key: "one"}, wait, wait,
    ]);
    fonts.dispose(); runtime.dispose();
    return 0;
  }
}
