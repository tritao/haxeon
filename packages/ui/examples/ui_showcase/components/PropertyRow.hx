package components;

import haxeon.ui.Color;
import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

/** Compact inspector line for a resolved property or runtime state value. */
class PropertyRow {
	public static function build(key:String, value:String, ?color:Color):KeyedView
		return new KeyedView(key, new Text(value, null, color, null, TextRole.Caption));
}
