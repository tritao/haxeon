import haxeon.reactive.Signal;
import haxeon.ui.component.BoundText;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.theme.Theme;

/** Cached mounted text must keep its native dependency owner alive. */
@:access(haxeon.ui.core.ViewRoot) class BindingLifetimeMain {
	static function main():Int {
		var store = new StateStore();
		var context = new BuildContext(store, null, null, null, Theme.light());
		var value = new Signal<Int>(0);
		// The outer scope describes the same inner body every time, so the inner scope is kept.
		var text:Void->haxeon.ui.core.View = () -> new BoundText("text", () -> Std.string(value.value));
		var view = new TrackedScope("lifetime", () -> new TrackedScope("stable", text));
		context.beginFrame();
		context.trackReads(() -> view.build(context).node());
		store.endFrame();
		context.beginFrame();
		var marker = context.stateUsageMarker();
		var root = context.trackReads(() -> view.build(context).node());
		var ids = context.stateIdsUsedSince(marker);
		store.endFrame();
		// Retain the native owner and its resources without rebuilding the mounted body.
		context.beginFrame();
		context.retainStateIds(ids);
		store.endFrame();
		value.value = 1;
		context.flushTextBindings(root);
		var textMatches = false;
		root.walk(node -> {
			if (node.layout.text == "1") textMatches = true;
		});
		var valid = value.hasFieldReaders(0) && textMatches;
		context.dispose();
		return valid ? 42 : 5;
	}
}
