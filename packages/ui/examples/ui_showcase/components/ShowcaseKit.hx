package components;

import UiExplorer;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Padding;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

/** Showcase-only styling and small compositions built from framework widgets. */
@:allow(UiExplorer) class ShowcaseKit {
	static function textField(explorer:UiExplorer):TextField {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(42.0);
		style.padding = new Insets(11.0, 8.0, 11.0, 8.0);
		style.background = explorer.state.lightTheme ? color(0.92, 0.94, 0.98) : color(0.09, 0.12, 0.18);
		style.radiusTopLeft = style.radiusTopRight = 5.0;
		style.radiusBottomLeft = style.radiusBottomRight = 5.0;
		return new TextField("demo-name", explorer.state.controls.nameValue, value -> {
			explorer.state.controls.nameValue = value;
		}, style, "Display name");
	}

	static function textArea(explorer:UiExplorer):TextField {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(146.0);
		style.padding = new Insets(11.0, 8.0, 11.0, 8.0);
		style.background = explorer.state.lightTheme ? color(0.92, 0.94, 0.98) : color(0.09, 0.12, 0.18);
		style.radiusTopLeft = style.radiusTopRight = 5.0;
		style.radiusBottomLeft = style.radiusBottomRight = 5.0;
		return new TextField("demo-notes", explorer.state.controls.notesValue, value -> {
			explorer.state.controls.notesValue = value;
		}, style, "Multilingual notes", multiline: true);
	}

	static function slider(explorer:UiExplorer):Slider {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(36.0);
		return new Slider("volume-slider", "Volume", explorer.state.controls.volume, 0.0, 1.0, 0.01, value -> {
			explorer.state.controls.volume = value;
		}, style);
	}

	public static function button(explorer:UiExplorer,
			label:String,
			key:String,
			action:Void->Void,
			selected:Bool = false,
			enabled:Bool = true,
			?leadingIcon:IconName,
			?style:LayoutStyle):Button return new Button(label,
		style == null ? buttonStyle() : style,
		action,
		key,
		enabled,
		null,
		selected,
		null,
		leadingIcon);

	public static function buttonStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.height = LayoutAxis.fixed(38.0);
		style.padding = new Insets(12.0, 9.0, 12.0, 9.0);
		style.radiusTopLeft = style.radiusTopRight = 5.0;
		style.radiusBottomLeft = style.radiusBottomRight = 5.0;
		return style;
	}

	static function disabledButton(explorer:UiExplorer, label:String):Button {
		var result = button(explorer, label, "disabled-demo", () -> {}, false, false);
		return result;
	}

	static function panel(explorer:UiExplorer, key:String, children:Array<KeyedView>):Column return new Column(key,
		children,
		panelStyle(explorer));

	static function panelStyle(explorer:UiExplorer, ?fixedWidth:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = fixedWidth == null ? LayoutAxis.grow() : LayoutAxis.fixed(fixedWidth);
		style.height = LayoutAxis.fit();
		style.padding = new Insets(16.0, 14.0, 16.0, 14.0);
		style.childGap = 10.0;
		style.background = explorer.state.lightTheme ? color(0.97, 0.98, 1.0) : color(0.10, 0.14, 0.22);
		style.radiusTopLeft = style.radiusTopRight = 7.0;
		style.radiusBottomLeft = style.radiusBottomRight = 7.0;
		return style;
	}

	static function columnStyle(explorer:UiExplorer, width:Float, height:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(width);
		style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(20.0, 18.0, 20.0, 18.0);
		style.childGap = 12.0;
		style.background = panelStyle(explorer).background;
		return style;
	}

	static function rowStyle(gap:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.direction = LayoutDirection.LeftToRight;
		style.childGap = gap;
		return style;
	}

	static function fixedBoxStyle(explorer:UiExplorer, width:Float, height:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(width);
		style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(10.0, 10.0, 10.0, 10.0);
		style.background = explorer.state.lightTheme ? color(0.88, 0.91, 0.96) : color(0.07, 0.10, 0.16);
		return style;
	}

	static function colorTile(label:String, background:Color, growWeight:Float = 1.0):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow(0.0, 0.0, growWeight);
		style.height = LayoutAxis.fixed(50.0);
		style.padding = new Insets(10.0, 10.0, 10.0, 10.0);
		style.background = background;
		style.radiusTopLeft = style.radiusTopRight = 5.0;
		style.radiusBottomLeft = style.radiusBottomRight = 5.0;
		return new Padding("tile-padding",
			new Text(label, null, color(1.0, 1.0, 1.0)),
			new Insets(10.0, 10.0, 10.0, 10.0),
			style);
	}

	static function stackDemo(explorer:UiExplorer):View {
		var rootStyle = fixedBoxStyle(explorer, 520.0, 122.0);
		rootStyle.width = LayoutAxis.grow();
		var layers:Array<StackChild> = [
			new StackChild("base",
				colorTile("base layer", color(0.16, 0.29, 0.45)),
				12.0,
				12.0,
				0,
				LayoutAxis.fixed(250.0),
				LayoutAxis.fixed(72.0)),
			new StackChild("top",
				colorTile("z-index 1", color(0.38, 0.26, 0.61)),
				190.0,
				36.0,
				1,
				LayoutAxis.fixed(220.0),
				LayoutAxis.fixed(68.0))
		];
		return new Stack("positioned-stack", layers, rootStyle);
	}

	static function keyed(key:String, view:View):KeyedView return new KeyedView(key, view);

	static function text(value:String, ?color:Color, role:TextRole = TextRole.Body):Text return new Text(value,
		null,
		color,
		null,
		role);

	static function heading(value:String):Text return text(value, null, TextRole.Heading);

	static function caption(value:String):Text return text(value, null, TextRole.Caption);

	static function label(value:String):Text return text(value, null, TextRole.Label);

	static function paletteBackground(explorer:UiExplorer):Color return explorer.state.lightTheme ? color(0.93,
		0.95,
		0.98) : color(0.065,
		0.085,
		0.13);

	static function paletteSidebar(explorer:UiExplorer):Color return explorer.state.lightTheme ? color(0.88,
		0.91, 0.96) : color(0.08,
		0.11,
		0.17);

	static function paletteText(explorer:UiExplorer):Color return explorer.context.buildContext.theme.tokens
		.textPrimary;

	static function paletteMuted(explorer:UiExplorer):Color return explorer.context.buildContext.theme.tokens
		.textSecondary;

	static inline function color(red:Float, green:Float, blue:Float, alpha:Float = 1.0):Color return Color.rgba(red,
		green,
		blue,
		alpha);
}
