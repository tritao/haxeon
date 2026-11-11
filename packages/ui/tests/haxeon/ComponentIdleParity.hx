import haxeon.reactive.Signal;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.component.BoundText;
import haxeon.ui.widgets.text.Text;

/** Mount either component in memory, then exercise real cached submissions without a native host. */
@:access(haxeon.ui.LayoutSession)
@:access(haxeon.ui.core.UiContext)
class ComponentIdleParity {
  static var ui:UiContext;
  static var frame:LayoutFrame;
  static var body:Void->View;
  static var source:Signal<String>;
  public static function prepare(mode:Int):Void {
    ui = new UiContext(new LayoutSession(cast 0));
    frame = new LayoutFrame(300, 80);
    ui.buildContext.setViewport(frame.width, frame.height);
    ui.buildContext.setEnvironmentViewport(frame.width, frame.height);
    source = new Signal<String>("one");
    var view:View = mode == 0 ? new TrackedScope("value", () -> new Text(source.value))
      : mode == 1 ? new BoundText("value", () -> source.value)
      : new TrackedScope("structure", () -> new BoundText("value", () -> source.value));
    body = () -> view;
    ui.buildContext.beginFrame();
    ui.root = ui.buildContext.trackReads(() -> view.build(ui.buildContext));
    ui.buildContext.captureRootDependencies();
    ui.stateStore.endFrame();
    var nodes = 0;
    ui.root.walk(_ -> nodes++);
    ui.submittedBuildKey = "idle";
    ui.submittedNodeCount = nodes;
    ui.submittedFrameWidth = frame.width;
    ui.submittedFrameHeight = frame.height;
    ui.submittedInteractionRevision = ui.interactionStates.revision;
    ui.submittedStyleRevision = ui.buildContext.styleRevision;
    ui.submittedAnimationRevision = ui.animations.revision;
    ui.submittedGestureRevision = ui.gestures.revision;
    ui.submittedTheme = ui.buildContext.theme;
    ui.submittedStyleSheet = ui.buildContext.styleSheet;
    ui.verifyRetentionEvery = 1;
    ui.submitCached(body, frame, "idle");
  }
  public static function perform(count:Int):Int {
    for (_ in 0...count) if (ui.submitCached(body, frame, "idle") != ui.root) return -1;
    return count;
  }
  static function main():Int {
    prepare(Std.parseInt(Sys.args()[0]));
    #if !wasm
    hl.Gc.censusStart(0);
    #end
    var result = perform(1024);
    #if !wasm
    hl.Gc.censusStop();
    hl.Gc.censusDump(Sys.args()[1]);
    #end
    return result == 1024 ? 42 : 1;
  }
}
