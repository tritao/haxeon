package haxeon.ui;

import NativeKitUI;

/** Immutable reusable path geometry resource. */
class Path extends NativeKitUIResource {
	@:allow(haxeon.ui.PathBuilder)
	private function new(value:nkui_resource)
		super(value);
}
