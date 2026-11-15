package components;

import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.text.Text;

/** Standard Explorer page title and supporting description. */
class PageHeader {
	public static function append(items:Array<KeyedView>, title:String, description:String):Void {
		items.push(new KeyedView("page-title", new Text(title, null, null, null, TextRole.Heading)));
		items.push(new KeyedView("page-description",
			new Text(description, null, null, null, TextRole.Caption)));
	}
}
