package haxeon.ui.core;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

/** Minimal last-resort view for errors raised while building or rendering a frame. */
class FrameworkErrorView implements View {
	final message:String;
	final stage:Int;

	public function new(message:String, stage:Int) {
		this.message = message == null ? "Unknown UI failure" : message;
		this.stage = stage;
	}

	public function build(context:BuildContext):RenderNode {
		var rootStyle = new LayoutStyle();
		rootStyle.width = LayoutAxis.grow();
		rootStyle.height = LayoutAxis.grow();
		rootStyle.padding = new Insets(36.0, 36.0, 36.0, 36.0);
		rootStyle.childGap = 14.0;
		rootStyle.background = Color.rgba(0.12, 0.018, 0.025, 1.0);

		var messageStyle = new LayoutStyle();
		messageStyle.width = LayoutAxis.grow();
		messageStyle.height = LayoutAxis.fit();

		return new Column("framework-error", [
			new KeyedView("title", new Text("HAXEON UI ERROR", null,
				Color.rgba(1.0, 0.42, 0.42, 1.0), null, TextRole.Heading)),
			new KeyedView("summary", new Text("The last frame failed while building or rendering.",
				null, Color.rgba(1.0, 0.88, 0.88, 1.0), null, TextRole.Label)),
			new KeyedView("stage", new Text('framework stage ${stage}', null,
				Color.rgba(1.0, 0.65, 0.65, 1.0), null, TextRole.Caption)),
			new KeyedView("message", new Text(message, messageStyle,
				Color.rgba(1.0, 0.92, 0.92, 1.0), null, TextRole.Body))
		], rootStyle).build(context);
	}
}
