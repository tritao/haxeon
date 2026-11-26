import haxeon.ui.LayoutNode;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.StateStore;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.IconButton;

/** A caller's modifier stays on a native control's root across interaction reruns. */
class IconButtonMain {
	static function main():Int {
		var store = new StateStore();
		var context = new BuildContext(store, null, null, null, Theme.light());
		context.beginFrame();
		var modifier = new RootModifier();
		var overlay = new RenderNode(context.id("caller-overlay"), LayoutVisualKind.Box);
		modifier.add(overlay);
		modifier.zIndex = 3;
		var root = context.build(new IconButton("search", IconName.Search, "Search"), modifier);
		store.endFrame();
		if (root.children.length != 2 || root.children[1] != overlay || root.layout.style.zIndex != 3) return 1;
		var button = root;
		if (button.semantics == null || button.semantics.role != AccessibilityRole.Button
			|| button.semantics.label != "Search" || !button.semantics.actions.contains(AccessibilityAction.Activate)
			|| !button.focusable || !button.enabled || context.canPatch(button)) return 2;
		var scopeOwner = context.interactionRenderScope(button);
		if (scopeOwner == null || scopeOwner.root != root) return 3;
		context.interactionStates.set(button.id, StyleState.Pressed);
		scopeOwner.markDirty();
		context.flushRenderScopes(root);
		root = context.currentRoot(root);
		var pressed = root;
		if (pressed == button
			|| !pressed.id.equals(button.id) || !pressed.states.contains(StyleState.Pressed)
			|| root.children.length != 2
			|| root.children[1] != overlay || overlay.parent != root || root.layout.style.zIndex != 3) return 4;
		context.beginFrame();
		var disabled = new IconButton("disabled", IconName.Close, "Close", null, null, false).build(context);
		store.endFrame();
		if (disabled.enabled || disabled.focusable
			|| disabled.semantics == null || !disabled.semantics.states.contains(AccessibilityState.Disabled)
			|| !disabled.states.contains(StyleState.Disabled)) return 5;
		// Equal inputs retain the mounted control. A new model with the same visible key gives it a new callback.
		var owner = new HistoryOwner();
		context.beginFrame();
		var first = new HistoryRow(owner).build(context);
		store.endFrame();
		var action:IconButton = cast HistoryRow.button;
		action.onClick();
		context.beginFrame();
		var same = new HistoryRow(owner).build(context);
		store.endFrame();
		if (same != first || HistoryRow.builds != 1 || owner.calls != 1) return 6;
		var replacement = new HistoryOwner();
		context.beginFrame();
		var changed = new HistoryRow(replacement).build(context);
		store.endFrame();
		action = cast HistoryRow.button;
		action.onClick();
		// The new model rebuilds the child; the button's inputs are equal apart from its callback, so its body is kept.
		if (changed != same || HistoryRow.builds != 2 || owner.calls != 1 || replacement.calls != 1) return 7;
		context.dispose();
		return 42;
	}
}

private class HistoryOwner {
	public var calls = 0;
	public function new() {}
}

/** A component whose only input is the model its undo button calls. */
private class HistoryRow implements ScopeView {
	public static var builds = 0;
	public static var button:Null<IconButton>;
	final owner:HistoryOwner;

	public function new(owner:HistoryOwner) this.owner = owner;

	public function scopeKey():String return "history";

	public function inputsEqual(previous:ScopeView):Bool {
		return Std.isOfType(previous, HistoryRow) && (cast previous:HistoryRow).owner == owner;
	}

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	public function buildBody(context:BuildContext):RenderNode {
		builds++;
		var model = owner;
		var undo = new IconButton("history", IconName.Undo, "Undo", () -> model.calls++);
		button = undo;
		return undo.build(context);
	}
}
