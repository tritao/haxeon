package components;

import haxeon.ui.Color;

import haxeon.ui.LayoutStyle;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.theme.TextRole;

/** Overview card composed from ordinary NativeKit layout and text widgets. */
class DemoCard {
	public static function build(key:String, title:String, value:String, description:String,
			style:LayoutStyle, eyebrowColor:Color):Column {
		return new Column(key, [
			new KeyedView("eyebrow", new Text(title, null, eyebrowColor, null, TextRole.Label)),
			new KeyedView("value", new Text(value, null, null, null, TextRole.Heading)),
			new KeyedView("description", new Text(description, null, null, null, TextRole.Caption))
		], style);
	}
}
