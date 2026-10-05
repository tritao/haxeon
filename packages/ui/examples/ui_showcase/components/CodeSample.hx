package components;

import haxeon.ui.Color;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

/** Syntax-colored snippet line for the inspector's API documentation view. */
class CodeSample {
	public static function build(key:String, code:String, color:Color):KeyedView
		return new KeyedView(key, new Text(code, null, color));
}
