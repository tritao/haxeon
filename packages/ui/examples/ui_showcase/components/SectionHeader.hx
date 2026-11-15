package components;

import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

/** Small muted label for catalog groups and demo sections. */
class SectionHeader {
	public static function build(key:String, label:String):KeyedView
		return new KeyedView(key, new Text(label, null, null, null, TextRole.Caption));
}
