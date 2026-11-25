package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;

/** Accessible boolean checkbox composed from Haxe layout and paint nodes. */
class Checkbox extends BinaryControl implements View {
	/** A checkbox labelled `label`, off unless `checked`; `onChange` receives each new value. */
	public function new(key:String, label:String, checked:Bool = false,
			?onChange:Bool->Void, ?style:LayoutStyle) {
		super(key, label, checked, false, onChange, style);
	}
}
