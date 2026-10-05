package components;

import haxeon.ui.LayoutStyle;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;

/** Simple responsive row container for peer demo cards. */
class DemoGrid {
	public static function build(key:String, children:Array<KeyedView>, style:LayoutStyle):Row
		return new Row(key, children, style);
}
