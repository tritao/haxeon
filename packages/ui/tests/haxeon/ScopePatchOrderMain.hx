import Equatable;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutChanges;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.component.BoundText;
import haxeon.ui.component.EqualChild;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/** Exercise the real submission queues before native layout, including dirty cached survivors. */
@:access(haxeon.ui.core.UiContext) class ScopePatchOrderMain {
  public static final LayoutBoundary = "patch-order layout boundary";
  public static final StaleRead = "patch-order stale removed child read";
  public static final RootFailure = "patch-order expected root failure";
  public static var lastError = "";

  public static function runCase(mode:Int):Int {
    var session = new OrderingLayoutSession();
    var ui = new UiContext(session);
    var view = new OrderingParent(mode == 6 ? 5 : mode);
    var frame = new LayoutFrame(300, 80);
    var context = ui.buildContext;
    context.setViewport(frame.width, frame.height);
    context.setEnvironmentViewport(frame.width, frame.height);
    context.beginFrame();
    ui.root = context.trackReads(() -> context.withScope(new Key("root"), () -> view.build(context)));
    context.captureRootDependencies();
    ui.stateStore.endFrame();
    ui.root.walk(node -> {ui.submittedNodes.push(node);
    ui.submittedTopology.append(node);
    ui.currentNodesById.set(node.id.value, node);
    });
    ui.submittedBuildKey = "patch-order";
    ui.submittedFrameWidth = frame.width;
    ui.submittedFrameHeight = frame.height;
    ui.submittedInteractionRevision = ui.interactionStates.revision;
    ui.submittedStyleRevision = context.styleRevision;
    ui.submittedAnimationRevision = ui.animations.revision;
    ui.submittedGestureRevision = ui.gestures.revision;
    ui.submittedTheme = context.theme;
    ui.submittedStyleSheet = context.styleSheet;
    if (mode == 6) {
      var scheduled = 0;
      ui.onAnimationFrameRequested = () -> scheduled++;
      view.reject = true;
      view.version.value = 1;
      view.value.value = 2;
      var rejected = false;
      try ui.submitCached(() -> view, frame, "patch-order") catch (error:Dynamic) {
        rejected = Std.string(error) == RootFailure;
      }
      var before = scheduled;
      view.value.value = 3;
      var valid = rejected && scheduled > before;
      if (!valid) lastError = "Failed root suppressed the next binding frame request";
      context.dispose();
      return valid ? 42 : 6;
    }
    view.version.value = 1;
    if (mode < 3) view.present.value = false;
    else view.value.value = 2;
    var reached = false;
    var failure = 0;
    try ui.submitCached(() -> view, frame, "patch-order") catch (error:Dynamic) {
      lastError = Std.string(error);
      if (Std.string(error) == LayoutBoundary) reached = true;
      else failure = Std.string(error) == StaleRead ? 1 : 2;
    }
    if (failure == 0 && (!reached || view.builds != 2)) failure = 3;
    if (failure == 0 && mode < 3 && (view.reads != 1 || session.children != 0)) failure = 4;
    if (failure == 0 && mode >= 3 && (view.reads < 2 || session.children != 1 || !session.sawUpdatedText)) {
      failure = 5;
      lastError = "survivor reads=" + view.reads + " children=" + session.children + " text=" + session.seenText;
    }
    context.dispose();
    return failure == 0 ? 42 : failure;
  }

  static function main():Int {
    #if !wasm
    var args = Sys.args();
    if (args.length > 0) {
      var result = runCase(Std.parseInt(args[0]));
      if (result != 42) Sys.println(lastError);
      return result;
    }
    #end
    for (mode in 0...7) if (runCase(mode) != 42) return mode + 1;
    return 42;
  }
}

@:access(haxeon.ui.LayoutSession) private class OrderingLayoutSession extends LayoutSession {
  public var children = -1;
  public var sawUpdatedText = false;
  public var seenText:Null<String>;
  public function new() super(cast 0);
  override public function submit(root:LayoutNode,
    frame:LayoutFrame, ?changes:LayoutChanges, forceFull:Bool = false):Array<ResolvedLayoutItem> {
    children = root.children.length;
    if (children == 1) {
      seenText = root.children[0].text;
      sawUpdatedText = seenText == "2";
    }
    throw ScopePatchOrderMain.LayoutBoundary;
  }
}

private struct StableChildInput implements Equatable {
  public final token:Int;
  public function new(token:Int) this.token = token;
}

private class OrderingParent implements View {
  public final present = new Signal<Bool>(true);
  public final version = new Signal<Int>(0);
  public final value = new Signal<Int>(1);
  public var builds = 0;
  public var reads = 0;
  public var reject = false;
  final child:View;
  final cached:EqualChild<StableChildInput>;
  final keep:Bool;
  public function new(mode:Int) {
    keep = mode >= 3;
    child = mode % 3 == 0 ? new OrderingLegacyLeaf(this) : mode % 3 == 1 ? new TrackedScope(
      "child",
      () -> new Text(read())
    ) : new BoundText(
      "child",
      read
    );
    cached = new EqualChild("cached-child", new StableChildInput(1), (_, _) -> child);
  }
  public function read():String {
    reads++;
    if (!present.value) throw ScopePatchOrderMain.StaleRead;
    return Std.string(value.value);
  }
  public function build(context:BuildContext):RenderNode {
    builds++;
    var revision = version.value;
    if (reject) throw ScopePatchOrderMain.RootFailure;
    var root = context.createNode(context.rootId("parent"), LayoutVisualKind.Box);
    root.layout.style.zIndex = revision;
    if (present.value) root.add(keep ? cached.build(context) : child.build(context));
    return root;
  }
}

private class OrderingLegacyLeaf implements View {
  final parent:OrderingParent;
  public function new(parent:OrderingParent) this.parent = parent;
  public function build(context:BuildContext):RenderNode {
    var id = context.rootId("legacy-child");
    return context.selfUpdating(id, () -> {var text = parent.read();
    var node = context.createNode(id, LayoutVisualKind.Text);
    node.layout.text = text;
    return node;
    }, false);
  }
}
