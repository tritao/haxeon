import haxeon.reactive.Signal;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutSizing;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.RetainedVariants;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.View;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleSelector;
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
    sheet.rule(StyleSelector.widget("button"), [StyleValue.width(LayoutAxis.fixed(120)),
      StyleValue.height(LayoutAxis.fixed(32)), StyleValue.positioning(LayoutPositioning.Absolute)]);
    sheet.rule(StyleSelector.widget("button").state(StyleState.Hovered), [StyleValue.width(LayoutAxis.fixed(150))]);
    context.setStyleSheet(sheet);
    var semantics = new Semantics(AccessibilityRole.ComboBox, "Choose", "First");
    semantics.actions = AccessibilityAction.Expand | AccessibilityAction.SetValue;
    var decoration = new ButtonDecoration(), focuses = 0, blurs = 0;
    context.beginFrame();
    var root = new Button("First", null, null, "choose", null, null, null, null, null, null, null, decoration, null, null, null, null, null, semantics).build(context);
    store.endFrame();
    var control = root;
    if (root.layout.style.width.value != 120 || root.layout.style.height.value != 32 ||
        root.layout.style.positioning != LayoutPositioning.Absolute || !root.hitTestSelf ||
        root.children.length != 2 || !control.focusable ||
        control.semantics != semantics || decoration.builds != 1) return 1;
    var events = new EventDispatcher(new FocusManager(), context.interactionStates);
    events.setRoot(root);
    root.on(UiEventKind.Focus, function(_) focuses++, "capture");
    root.on(UiEventKind.Blur, function(_) blurs++, "capture");
    events.focusEvent(control.id, UiEventKind.Focus);
    events.focusEvent(control.id, UiEventKind.Blur);
    if (focuses != 1 || blurs != 1) return 6;
    var owner = context.interactionRenderScope(control);
    if (owner == null || owner.root != root || context.canPatch(control)) return 2;
    var extra = context.createNode(context.rootId("caller-extra"), LayoutVisualKind.Box);
    root.add(extra);
    if (context.interactionRenderScope(extra) != null || owner.owns(extra) || !owner.owns(root.children[0])) return 13;
    root.layout.style.zIndex = 9;
    context.interactionStates.set(control.id, StyleState.Hovered);
    owner.markDirty();
    context.flushRenderScopes();
    root = context.currentRoot(root);
    var refreshed = root;
    var refreshedSemantics = refreshed.semantics;
    if (refreshedSemantics == null) return 5;
    if (refreshed == control || !refreshed.id.equals(control.id) || refreshed.semantics != semantics ||
        refreshedSemantics.value != "First" || refreshedSemantics.actions != semantics.actions ||
        !refreshed.states.contains(StyleState.Hovered) || decoration.builds != 2 ||
        root.children.length != 3 || root.children[2] != extra || extra.parent != root ||
        root.layout.style.width.value != 150 || root.layout.style.zIndex != 9) return 3;
    events.setRoot(root);
    events.focusEvent(refreshed.id, UiEventKind.Focus);
    events.focusEvent(refreshed.id, UiEventKind.Blur);
    if (focuses != 2 || blurs != 2) return 7;
    context.beginFrame();
    var disabled = new Button("Disabled", null, null, "disabled", false).build(context);
    store.endFrame();
    if (disabled.enabled || disabled.focusable || !disabled.states.contains(StyleState.Disabled)) return 4;
    var parentBuilds = 0, parentEnabled = new Signal<Bool>(true);
    var parent = new RetainedView("cached-button-parent", function(_) {
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
    context.flushRenderScopes();
    context.beginFrame();
    var reusedRoot = context.trackReads(function() return parent.build(context));
    store.endFrame();
    if (parentBuilds != 1 || reusedRoot != context.currentRoot(cachedRoot) ||
        !reusedRoot.states.contains(StyleState.Hovered) ||
        reusedRoot.layout.style.width.value != 150) return 8;
    context.interactionStates.set(cachedControl.id, StyleState.Focused);
    cachedOwner.markDirty();
    context.flushRenderScopes();
    context.beginFrame();
    reusedRoot = context.trackReads(function() return parent.build(context));
    store.endFrame();
    if (parentBuilds != 1 || reusedRoot != context.currentRoot(cachedRoot) ||
        !reusedRoot.states.contains(StyleState.Focused) ||
        reusedRoot.layout.style.width.value != 120) return 10;
    parentEnabled.value = false;
    context.beginFrame();
    var changedRoot = context.trackReads(function() return parent.build(context));
    store.endFrame();
    if (parentBuilds != 2 || changedRoot == cachedRoot || changedRoot.enabled ||
        changedRoot.focusable || !cachedOwner.disposed) return 11;
    var variantBuilds = 0;
    var variant = new RetainedVariants("native-variant", "one", function(_) {
      variantBuilds++;
      return new ButtonWithCallerExtra();
    });
    context.beginFrame();
    var variantRoot = context.trackReads(function() return variant.build(context));
    store.endFrame();
    var variantBody = variantRoot, outside = variantRoot.children[1];
    var variantOwner = context.renderScopeAt(variantRoot);
    if (variantOwner == null || context.interactionRenderScope(outside) != null) return 14;
    context.interactionStates.set(variantBody.id, StyleState.Hovered);
    variantOwner.markDirty();
    context.flushRenderScopes();
    context.beginFrame();
    var keptVariant = context.trackReads(function() return variant.build(context));
    store.endFrame();
    if (variantBuilds != 1 || keptVariant != context.currentRoot(variantRoot) || keptVariant.children[1] != outside ||
        keptVariant == variantBody || keptVariant.layout.style.width.value != 150) return 12;
    outside.detach();
    context.beginFrame();
    var rebuiltVariant = context.trackReads(function() return variant.build(context));
    store.endFrame();
    if (variantBuilds != 2 || rebuiltVariant == keptVariant || rebuiltVariant.children.length != 2) return 15;
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

/** The extra is attached by the component caller, outside the independently replaced body. */
private class ButtonWithCallerExtra implements View {
  public function new() {}
  public function build(context:BuildContext):RenderNode {
    var root = new Button("Variant", null, null, "variant-button").build(context);
    var extra = context.createNode(context.rootId("outside-body"), LayoutVisualKind.Box);
    extra.states = StyleState.empty();
    root.add(extra);
    return root;
  }
}
