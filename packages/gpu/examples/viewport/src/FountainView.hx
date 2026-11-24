import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.GpuViewport;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

/** Controls beside a viewport that shows the fountain the app draws on the GPU. */
class FountainView implements View {
	final fountain:Fountain;
	final viewport:GpuViewport;

	public function new(fountain:Fountain, viewport:GpuViewport) {
		this.fountain = fountain;
		this.viewport = viewport;
	}

	public function build(context:BuildContext):RenderNode {
		var controls = new Column("controls", [
			new KeyedView("title", new Text("Fountain")),
			new KeyedView("gravity-label", new Text("Gravity")),
			new KeyedView("gravity", new Slider("gravity", "Gravity", fountain.gravity, 0.3, 3.0, 0.1,
				value -> fountain.gravity = value)),
			new KeyedView("spread-label", new Text("Spread")),
			new KeyedView("spread", new Slider("spread", "Spread", fountain.spread, 0.0, 2.0, 0.1,
				value -> fountain.spread = value)),
			new KeyedView("warm", new Toggle("warm", "Warm colours", fountain.warm,
				value -> fountain.warm = value)),
			new KeyedView("reset", new Button("Reset", null, fountain.reset))
		], sidebarStyle());
		var row = new Row("root", [
			new KeyedView("controls", controls),
			new KeyedView("viewport", viewport)
		], rootStyle());
		return row.build(context);
	}

	static function sidebarStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(240);
		style.height = LayoutAxis.grow();
		style.padding = new Insets(20, 20, 20, 20);
		style.childGap = 16;
		style.background = Color.rgba(0.09, 0.11, 0.16, 1);
		return style;
	}

	static function rootStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		return style;
	}
}
