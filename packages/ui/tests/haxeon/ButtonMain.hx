import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleValue;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.controls.Button;

/** Constructor composition and resolved outer layout survive native interaction reruns. */
class ButtonMain {
	static function main():Int {
		var store = new StateStore();
		var context = new BuildContext(store, null, null, null, Theme.light());
		var sheet = new StyleSheet("button-layout");
		sheet.rule(StyleSelector.widget("button"),
			[
				StyleValue.width(LayoutAxis.fixed(120)),
				StyleValue.height(LayoutAxis.fixed(32)),
				StyleValue.positioning(LayoutPositioning.Absolute)
			]);
		sheet.rule(StyleSelector.widget("button").state(StyleState.Hovered), [StyleValue.width(LayoutAxis.fixed(150))]);
		context.setStyleSheet(sheet);
		var semantics = new Semantics(AccessibilityRole.ComboBox, "Choose", "First");
		semantics.actions = AccessibilityAction.Expand | AccessibilityAction.SetValue;
		var decoration = new ButtonDecoration(), focuses = 0, blurs = 0;
		// What the caller adds goes through a modifier: listeners, a placement and an extra child.
		var modifier = new RootModifier();
		modifier.on(UiEventKind.Focus, function(_) focuses++, UiEventPhase.Capture);
		modifier.on(UiEventKind.Blur, function(_) blurs++, UiEventPhase.Capture);
		modifier.zIndex = 9;
		context.beginFrame();
		var extra = context.createNode(context.rootId("caller-extra"), LayoutVisualKind.Box);
		modifier.add(extra);
		var root = context.build(new Button("First",
			null,
			null,
			"choose",
			null,
			null,
			null,
			null,
			null,
			null,
			null,
			decoration,
			null,
			null,
			null,
			null,
			null,
			semantics), modifier);
		store.endFrame();
		var control = root;
		if (root.layout.style.width.value != 120 || root.layout.style.height.value != 32
			|| root.layout.style.positioning != LayoutPositioning.Absolute || !root.hitTestSelf
			|| root.children.length != 3 || root.layout.style.zIndex != 9
			|| !control.focusable || control.semantics != semantics || decoration.builds != 1) return 1;
		var events = new EventDispatcher(new FocusManager(), context.interactionStates);
		events.setRoot(root);
		events.focusEvent(control.id, UiEventKind.Focus);
		events.focusEvent(control.id, UiEventKind.Blur);
		if (focuses != 1 || blurs != 1) return 6;
		var owner = context.interactionRenderScope(control);
		if (owner == null || owner.root != root || context.canPatch(control)) return 2;
		if (context.interactionRenderScope(extra) != null || owner.owns(extra)
			|| !owner.owns(root.children[0])) return 13;
		context.interactionStates.set(control.id, StyleState.Hovered);
		owner.markDirty();
		context.flushRenderScopes(root);
		root = context.currentRoot(root);
		var refreshed = root;
		var refreshedSemantics = refreshed.semantics;
		if (refreshedSemantics == null) return 5;
		if (refreshed == control
			|| !refreshed.id.equals(control.id) || refreshed.semantics != semantics
			|| refreshedSemantics.value != "First"
			|| refreshedSemantics.actions != semantics.actions || !refreshed.states.contains(StyleState.Hovered)
			|| decoration.builds != 2 || root.children.length != 3 || root.children[2] != extra
			|| extra.parent != root || root.layout.style.width.value != 150 || root.layout.style.zIndex != 9) return 3;
		events.setRoot(root);
		events.focusEvent(refreshed.id, UiEventKind.Focus);
		events.focusEvent(refreshed.id, UiEventKind.Blur);
		if (focuses != 2 || blurs != 2) return 7;
		context.beginFrame();
		var disabled = new Button("Disabled", null, null, "disabled", false).build(context);
		store.endFrame();
		if (disabled.enabled || disabled.focusable || !disabled.states.contains(StyleState.Disabled)) return 4;
		var parentBuilds = 0, parentEnabled = new Signal<Bool>(true);
		var parent = new TrackedScope("cached-button-parent", function() {
			parentBuilds++;
			return new Button("Cached", null, null, "cached-button", parentEnabled.value);
		});
		context.beginFrame();
		var cachedRoot = context.trackReads(function() return parent.build(context));
		store.endFrame();
		var cachedControl = cachedRoot;
		var cachedOwner = context.interactionRenderScope(cachedControl);
		if (cachedOwner == null) return 9;
		context.interactionStates.set(cachedControl.id, StyleState.Hovered);
		cachedOwner.markDirty();
		context.flushRenderScopes(cachedRoot);
		context.beginFrame();
		var reusedRoot = context.trackReads(function() return parent.build(context));
		store.endFrame();
		if (parentBuilds != 1 || reusedRoot != context.currentRoot(cachedRoot)
			|| !reusedRoot.states.contains(StyleState.Hovered) || reusedRoot.layout.style.width.value != 150) return 8;
		context.interactionStates.set(cachedControl.id, StyleState.Focused);
		cachedOwner.markDirty();
		context.flushRenderScopes(reusedRoot);
		context.beginFrame();
		reusedRoot = context.trackReads(function() return parent.build(context));
		store.endFrame();
		if (parentBuilds != 1 || reusedRoot != context.currentRoot(cachedRoot)
			|| !reusedRoot.states.contains(StyleState.Focused) || reusedRoot.layout.style.width.value != 120) return 10;
		parentEnabled.value = false;
		context.beginFrame();
		var changedRoot = context.trackReads(function() return parent.build(context));
		store.endFrame();
		// The parent runs again and describes the button with new inputs; the button's own scope builds them.
		if (parentBuilds != 2 || changedRoot.enabled || changedRoot.focusable) return 11;
		context.dispose();
		return 42;
	}
}

private class ButtonDecoration implements View {
	public var builds = 0;
	public function new() {}
	public function build(context:BuildContext):RenderNode {
		if (context.inheritedStyle == null) throw "Button child did not inherit computed style";
		builds++;
		return context.createNode(context.rootId("decoration"), LayoutVisualKind.Box);
	}
}
