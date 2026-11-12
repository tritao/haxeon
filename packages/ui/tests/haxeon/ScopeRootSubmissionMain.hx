import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;

/** A cached submission follows a replaced top-level body, with fresh verification on every changed frame. */
class ScopeRootSubmissionMain {
  static function main():Int return run();

  public static function run():Int {
    var session = LayoutSession.create(), ui = new UiContext(session);
    ui.verifyRetentionEvery = 1;
    var width = new Signal<Int>(80), view = new ScopeSubmissionView(width);
    var frame = new LayoutFrame(200, 80);
    var build = () -> view;
    var first = ui.submitCached(build, frame, "scope-root");
    if (!ui.focusWidget(first.id) || view.focuses != 1) return 1;
    var builds = view.builds;
    width.value = 120;
    var next = ui.submitCached(build, frame, "scope-root");
    if (next == first || !next.id.equals(first.id) || next.layout.style.width.value != 120
      || next.layout.style.zIndex != 7 || next.children.length != 1 || view.builds != builds + 1
      || view.focuses != 1 || ui.focus.focusedId == null || !ui.focus.focusedId.equals(next.id)) return 2;
    ui.dispose();
    session.dispose();
    return 42;
  }
}

private class ScopeSubmissionView implements View {
  final scope:TrackedScope;
  public var builds = 0;
  public var focuses = 0;
  public function new(width:Signal<Int>) scope = new TrackedScope("width", () -> new SubmissionBox(width.value));
  public function build(context:BuildContext):RenderNode {
    builds++;
    var root = scope.build(context);
    root.layout.style.zIndex = 7;
    root.on(UiEventKind.Focus, _ -> focuses++, "capture");
    root.add(context.createNode(context.id("overlay")));
    return root;
  }
}

private class SubmissionBox implements View {
  final width:Int;
  public function new(width:Int) this.width = width;
  public function build(context:BuildContext):RenderNode {
    var id = context.rootId("body"), style = new LayoutStyle();
    style.width = LayoutAxis.fixed(width);
    style.height = LayoutAxis.fixed(24);
    var root = context.createNode(id, LayoutVisualKind.Box, style);
    root.focusable = true;
    root.states = context.interactionStates.get(id);
    return root;
  }
}
