import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.component.BoundText;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleState;

/** A component the outer scope describes with equal inputs every time, so its body is kept. */
class FeedbackBody implements ScopeView {
	final value:Int;
	final revision:Signal<Int>;
	public function new(value:Int, revision:Signal<Int>) {
		this.value = value;
		this.revision = revision;
	}
	public function scopeKey():String return "body";
	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, FeedbackBody)) return false;
		var other:FeedbackBody = cast previous;
		return value == other.value && revision == other.revision;
	}
	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);
	public function buildBody(context:BuildContext):ViewRoot return new FeedbackGeometry(revision).build(context);
}

class FeedbackGeometry implements View {
	final revision:Signal<Int>;
	public function new(revision:Signal<Int>) this.revision = revision;
	public function build(context:BuildContext):ViewRoot {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(100);
		style.height = LayoutAxis.fixed(100);
		var root = context.createNode(context.rootId("viewport"), LayoutVisualKind.Box, style);
		root.states = context.interactionStates.get(root.id);
		var barStyle = new LayoutStyle();
		// The bar shows once the first frame is built: its body reruns alone for it, and the outer scope after it.
		var shown = context.state(context.id("bar-shown"), false);
		barStyle.width = LayoutAxis.fixed(5);
		barStyle.height = LayoutAxis.fixed(shown.value ? 40 : 0);
		barStyle.positioning = LayoutPositioning.Absolute;
		barStyle.positionX = shown.value ? 50 : 0;
		barStyle.visible = shown.value;
		root.add(context.createNode(context.rootId("bar"), LayoutVisualKind.Box, barStyle));
		context.afterBuild(() -> {
			if (!shown.value) shown.update(true);
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
			return new FeedbackBody(1, revision);
		});
		ui.verifyRetentionEvery = 1;
		var frame = new LayoutFrame(200, 200);
		var builds = 0;
		function build():View {
			builds++;
			return view;
		}
		ui.submitCached(build, frame, "feedback");
		var before = builds;
		var mounted = ui.root;
		if (mounted == null) return 3;
		ui.interactionStates.set(mounted.id, StyleState.Pressed);
		revision.value = 2;
		ui.submitCached(build, frame, "feedback");
		// The local update needs no outer build; every-frame verification still performs its fresh build.
		if (builds != before + 1) return 2;
		mounted = ui.root;
		if (mounted == null) return 4;
		ui.interactionStates.set(mounted.id, StyleState.empty());
		before = builds;
		ui.submitCached(build, frame, "feedback");
		if (builds != before + 1) return 5;
		var valid = ui.verifyRetention(() -> view, frame) == null;
		ui.dispose();
		session.dispose();
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
		if (mounted == null) {
			Sys.println("LIVE TEXT missing changed root");
			return false;
		}
		if (mounted.layout.text != source.value || mounted.contentRevision != revision + 1) {
			Sys.println("LIVE TEXT changed: text="
				+ mounted.layout.text + " revision=" + revision + "->" + mounted.contentRevision);
			return false;
		}
		revision = mounted.contentRevision;
		source.value = "temporary";
		source.value = "a much longer value";
		ui.submitCached(() -> view, frame, "live");
		mounted = ui.root;
		if (mounted == null || mounted.contentRevision != revision) {
			Sys.println("LIVE TEXT unchanged revision");
			return false;
		}
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
		ui.dispose();
		session.dispose();
		fonts.dispose();
		if (!rejected) Sys.println("LIVE TEXT unrelated style edit was not rejected");
		if (!textRejected) Sys.println("LIVE TEXT unannounced text edit was not rejected");
		return rejected && textRejected;
	}
}
