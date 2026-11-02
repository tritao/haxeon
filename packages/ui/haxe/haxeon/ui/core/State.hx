package haxeon.ui.core;

import haxeon.reactive.Signal;

/** Stable signal handle for one value in a UiContext's persistent state store. */
class State<T> extends Signal<T> {
	final store:StateStore;
	public final id:WidgetId;

	@:allow(haxeon.ui.core.StateStore)
	private function new(store:StateStore, id:WidgetId, initial:T) {
		super(initial);
		this.store = store;
		this.id = id;
	}

	@:allow(haxeon.ui.core.StateStore)
	override function get_value():T {
		store.check(id);
		return super.get_value();
	}
}
