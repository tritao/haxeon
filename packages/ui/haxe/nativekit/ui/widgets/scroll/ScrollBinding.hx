package nativekit.ui.widgets.scroll;

import nativekit.ui.animation.AnimationScheduler;

/** Mount-owned binding; replacing or unmounting a viewport retires its animation. */
class ScrollBinding {
	var controller:Null<ScrollController>;
	public function new() {}
	public function attach(value:ScrollController, scheduler:AnimationScheduler, changed:ScrollController->Void):Void {
		if (controller != value) {
			dispose(); controller = value;
		}
		value.bind(changed, scheduler, this);
	}
	public function dispose():Void {
		if (controller != null) controller.unbind(this);
		controller = null;
	}
}
