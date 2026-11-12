import Equatable;
import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.FontCollection;
import haxeon.ui.component.EqualChild;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.component.BoundText;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleState;

struct FeedbackProps implements Equatable {
  public var value:Int;
  public function new(value:Int) this.value = value;
}

class FeedbackGeometry implements View {
  final revision:Signal<Int>;
  public function new(revision:Signal<Int>) this.revision = revision;
  public function build(context:BuildContext):RenderNode {
    var style = new LayoutStyle();
    style.width = LayoutAxis.fixed(100); style.height = LayoutAxis.fixed(100);
    var root = new RenderNode(context.id("viewport"), LayoutVisualKind.Box, style);
    root.states = context.interactionStates.get(root.id);
    var barStyle = new LayoutStyle();
    barStyle.width = LayoutAxis.fixed(5); barStyle.height = LayoutAxis.fixed(0);
    barStyle.positioning = LayoutPositioning.Absolute; barStyle.visible = false;
    var bar = root.add(new RenderNode(context.id("bar"), LayoutVisualKind.Box, barStyle));
    root.onResolved(_ -> {
      if (!bar.layout.style.visible) {
        context.willEditRetained(bar);
        bar.layout.style.height = LayoutAxis.fixed(40);
        bar.layout.style.positionX = 50;
        bar.layout.style.visible = true;
        context.requestLayoutFeedback();
      }
      if (revision.value == 0) revision.value = 1;
    });
    return root;
  }
}

class NativeScopeFeedbackMain {
  static function main():Int {
    var session = LayoutSession.create(), ui = new UiContext(session), revision = new Signal<Int>(0);
    var view:View = new TrackedScope("feedback", () -> {
      var value = revision.value;
      return new EqualChild<FeedbackProps>("body", new FeedbackProps(1), (_, _) -> new FeedbackGeometry(revision));
    });
    ui.verifyRetentionEvery = 1;
    var frame = new LayoutFrame(200, 200);
    var builds = 0;
    function build():View { builds++; return view; }
    ui.submitCached(build, frame, "feedback");
    var before = builds;
    var mounted = ui.root;
    if (mounted == null) return 3;
    ui.interactionStates.set(mounted.children[0].id, StyleState.Pressed);
    revision.value = 2;
    ui.submitCached(build, frame, "feedback");
    // The local update needs no outer build; every-frame verification still performs its fresh build.
    if (builds != before + 1) return 2;
    mounted = ui.root;
    if (mounted == null) return 4;
    ui.interactionStates.set(mounted.children[0].id, StyleState.empty());
    before = builds;
    ui.submitCached(build, frame, "feedback");
    if (builds != before + 1) return 5;
    var valid = ui.verifyRetention(() -> view, frame) == null;
    ui.dispose(); session.dispose();
    return valid && liveText() ? 42 : 1;
  }

  static function liveText():Bool {
    var fontPath = Sys.getEnv("NKUI_TEST_FONT_PATH");
    if (fontPath == null) return false;
    var fonts = FontCollection.create();
    fonts.add(fontPath);
    var session = LayoutSession.create(), ui = new UiContext(session, fonts);
    ui.verifyRetentionEvery = 1;
    var source = new Signal<String>("one"), frame = new LayoutFrame(200, 100);
    var view:View = new BoundText("live", () -> source.value);
    ui.submitCached(() -> view, frame, "live");
    var mounted = ui.root;
    if (mounted == null) return false;
    var revision = mounted.contentRevision;
    source.value = "a much longer value";
    ui.submitCached(() -> view, frame, "live");
    mounted = ui.root;
    if (mounted == null) { Sys.println("LIVE TEXT missing changed root"); return false; }
    if (mounted.layout.text != source.value || mounted.contentRevision != revision + 1) {
      Sys.println("LIVE TEXT changed: text=" + mounted.layout.text + " revision=" + revision + "->" + mounted.contentRevision);
      return false;
    }
    revision = mounted.contentRevision;
    source.value = "temporary";
    source.value = "a much longer value";
    ui.submitCached(() -> view, frame, "live");
    mounted = ui.root;
    if (mounted == null || mounted.contentRevision != revision) { Sys.println("LIVE TEXT unchanged revision"); return false; }
    // A binding's announced text must never hide an unrelated style mutation.
    var width = mounted.layout.style.width;
    mounted.layout.style.width = LayoutAxis.fixed(111);
    source.value = "another value";
    var rejected = false;
    try ui.submitCached(() -> view, frame, "live") catch (error:Dynamic) {
      rejected = Std.string(error).indexOf("changed without willEditRetained") >= 0;
    }
    mounted.layout.style.width = width;
    mounted.layout.text = "unannounced text";
    ui.buildContext.requestBindingFrame();
    var textRejected = false;
    try ui.submitCached(() -> view, frame, "live") catch (error:Dynamic) {
      textRejected = Std.string(error).indexOf("changed without willEditRetained") >= 0;
    }
    ui.dispose(); session.dispose(); fonts.dispose();
    if (!rejected) Sys.println("LIVE TEXT unrelated style edit was not rejected");
    if (!textRejected) Sys.println("LIVE TEXT unannounced text edit was not rejected");
    return rejected && textRejected;
  }
}
