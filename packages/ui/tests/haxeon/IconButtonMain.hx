import Equatable;
import haxeon.ui.LayoutNode;
import haxeon.ui.component.EqualChild;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.IconButton;

/** A caller's modifier stays on a native control's root across interaction reruns. */
class IconButtonMain {
	static var historyBuilds = 0;
	static var historyButton:Null<IconButton>;

	static function history(input:HistoryInput, context:BuildContext):View {
		historyBuilds++;
		var owner = input.owner;
		historyButton = new IconButton("history", IconName.Undo, "Undo", () -> owner.calls++);
		return cast historyButton;
	}
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
		var first = new EqualChild("history", new HistoryInput(owner), history).build(context);
		store.endFrame();
		var action:IconButton = cast historyButton;
		action.onClick();
		context.beginFrame();
		var same = new EqualChild("history", new HistoryInput(owner), history).build(context);
		store.endFrame();
		if (same != first || historyBuilds != 1 || owner.calls != 1) return 6;
		var replacement = new HistoryOwner();
		context.beginFrame();
		var changed = new EqualChild("history", new HistoryInput(replacement), history).build(context);
		store.endFrame();
		action = cast historyButton;
		action.onClick();
		// The new model rebuilds the child; the button's inputs are equal apart from its callback, so its body is kept.
		if (changed != same || historyBuilds != 2 || owner.calls != 1 || replacement.calls != 1) return 7;
		context.dispose();
		return 42;
	}
}

private class HistoryOwner {
	public var calls = 0;
	public function new() {}
}

private struct HistoryInput implements Equatable {
	public final owner:HistoryOwner;
	public function new(owner:HistoryOwner) this.owner = owner;
	public function equals(other:HistoryInput):Bool return owner == other.owner;
}
