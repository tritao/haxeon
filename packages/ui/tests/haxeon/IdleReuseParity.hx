import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;

/** Seed an already submitted tree so all targets exercise the real reuse branch without a native host. */
@:access(haxeon.ui.LayoutSession)
@:access(haxeon.ui.core.UiContext)
class IdleReuseParity {
  static var ui:UiContext;
  static var frame:LayoutFrame;
  static var body:Void->View;
  public static function prepare():Void {
    var session = new LayoutSession(cast 0);
    ui = new UiContext(session);
    frame = new LayoutFrame(300, 80);
    ui.buildContext.setViewport(frame.width, frame.height);
    ui.buildContext.setEnvironmentViewport(frame.width, frame.height);
    body = () -> null;
    ui.root = new RenderNode(new WidgetId(1), LayoutVisualKind.Box);
    ui.submittedBuildKey = "idle";
    ui.submittedNodeCount = 1;
    ui.submittedFrameWidth = frame.width;
    ui.submittedFrameHeight = frame.height;
    ui.submittedInteractionRevision = ui.interactionStates.revision;
    ui.submittedStyleRevision = ui.buildContext.styleRevision;
    ui.submittedAnimationRevision = ui.animations.revision;
    ui.submittedGestureRevision = ui.gestures.revision;
    ui.submittedTheme = ui.buildContext.theme;
    ui.submittedStyleSheet = ui.buildContext.styleSheet;
    ui.buildContext.captureRootDependencies();
    ui.verifyRetentionEvery = 1;
    ui.submitCached(body, frame, "idle");
  }
  public static function perform(count:Int):Int {
    for (_ in 0...count) if (ui.submitCached(body, frame, "idle") != ui.root) return -1;
    return count;
  }
  static function main():Int {
    prepare();
    #if !wasm
    hl.Gc.censusStart(0);
    #end
    var result = perform(1024);
    #if !wasm
    hl.Gc.censusStop();
    hl.Gc.censusDump(Sys.args()[0]);
    #end
    return result == 1024 ? 42 : 1;
  }
}
