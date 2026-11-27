package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;

/** Accessible switch-style boolean control composed on the Haxe side. */
class Toggle extends BinaryControl implements View {
	/** A switch labelled `label`, off unless `checked`; `onChange` receives each new value. */
	public function new(key:String, label:String, checked:Bool = false,
			?onChange:Bool->Void, ?style:LayoutStyle, ?accessibilityLabel:String, indeterminate:Bool = false,
			enabled:Bool = true) {
		super(key, label, checked, true, onChange, style, accessibilityLabel, indeterminate, enabled);
	}
}
