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

  public function new(fonts:FontCollection, restyleInPlace:Bool) {
    ui = new UiContext(null, fonts);
    ui.buildContext.environment.reducedMotion = true;
    ui.buildContext.restyleInPlace = restyleInPlace;
    var rig = this;
    var panel = new RetainedView("panel", function(_) {
      rig.panelBuilds++;
      return new Column("column", [
        new KeyedView("one", new Button("One", null, function() rig.clicks++, "one")),
        new KeyedView("two", new Button("Two", null, function() rig.clicks++, "two")),
        new KeyedView("decorated", rig.decorated),
      ]);
    });
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
      out.add(node.id.value + "|" + node.styleType + "|" + node.states + "|" + color.red + "," + color.green + "," + color.blue + "," + color.alpha
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

  public static function main():Int {
    var runtime = Runtime.start();
    var fonts = FontCollection.create();
    fonts.addSystemFallbacks();
    var patched = new Rig(fonts, true), reference = new Rig(fonts, false);
    var patchedRoot = patched.submit(), referenceRoot = reference.submit();
    check(signature(patchedRoot) == signature(referenceRoot), "The first frames differ");
    var script:Array<{action:String, key:String}> = [
      {action: "move", key: "one"}, {action: "move", key: "two"}, {action: "move", key: "decorated"},
      {action: "down", key: "decorated"}, {action: "up", key: "decorated"}, {action: "move", key: "one"},
      {action: "down", key: "one"}, {action: "move", key: "two"}, {action: "up", key: "two"},
      {action: "move", key: "decorated"}, {action: "away", key: "one"}, {action: "move", key: "two"},
      {action: "down", key: "two"}, {action: "up", key: "two"},
    ];
    var changed = 0;
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
          default: rig.ui.pointerMove(-20.0, -20.0);
        }
        var root = rig.submit();
        if (rig == patched) patchedRoot = root; else referenceRoot = root;
      }
      check(signature(patchedRoot) == signature(referenceRoot),
        "Step " + index + " (" + step.action + " " + step.key + ") differs from the full rebuild:\n--- patched\n" + signature(patchedRoot)
        + "--- reference\n" + signature(referenceRoot));
      if (signature(patchedRoot) != before) changed++;
      if (Sys.args().indexOf("--trace") >= 0) Sys.println(step.action + " " + step.key + ": panel builds +" + (patched.panelBuilds - buildsBefore));
    }
    check(changed >= 6, "Pointer changes did not restyle the buttons (" + changed + ")");
    check(patched.clicks == reference.clicks && patched.clicks > 0, "Clicks differ: " + patched.clicks + " vs " + reference.clicks);
    check(patched.decorated.presses == reference.decorated.presses && patched.decorated.presses > 0,
      "A listener added after build was lost: " + patched.decorated.presses + " vs " + reference.decorated.presses);
    var decoratedNode:Null<RenderNode> = null;
    patchedRoot.walk(function(node) { if (node.styleKey == "decorated" && node.styleType == "button") decoratedNode = node; });
    check(decoratedNode != null && decoratedNode.layout.style.zIndex == 3, "A style change made after build was lost");
    check(patched.panelBuilds == 1, "Pointer changes rebuilt the retained panel " + patched.panelBuilds + " times");
    check(reference.panelBuilds > patched.panelBuilds, "The reference did not rebuild the panel");
    Sys.println("PASS: " + script.length + " pointer steps match a full rebuild (" + changed + " restyled); panel builds patched="
      + patched.panelBuilds + " reference=" + reference.panelBuilds);
    patched.ui.dispose(); reference.ui.dispose(); fonts.dispose(); runtime.dispose();
    return 0;
  }
}
