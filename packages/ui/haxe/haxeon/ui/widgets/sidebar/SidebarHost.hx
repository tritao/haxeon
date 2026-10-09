package haxeon.ui.widgets.sidebar;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabsOptions;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import haxeon.ui.widgets.text.Text;

/** One content-owned tab strip; inactive providers never build. */
class SidebarHost implements View {
	final key:String;
	final model:SidebarModel;
	final onSelect:String->Void;
	final iconProvider:Null<String->Null<haxeon.ui.icons.IconName>>;
	final activeOnly:Bool;
	/** Optional fixed header actions for the active destination. */
	public var headerActions:Null<String->Null<View>> = null;
	/** Evaluate against the built pane; hidden actions retain their layout space. */
	public var headerActionsVisible:Null<RenderNode->Bool> = null;
	public function new(key:String, model:SidebarModel, onSelect:String->Void, ?iconProvider:String->Null<haxeon.ui.icons.IconName>, activeOnly:Bool = false) {
		this.activeOnly = activeOnly;
		this.iconProvider = iconProvider;
		this.key = key; this.model = model; this.onSelect = onSelect;
	}
	public function build(context:BuildContext):RenderNode {
		if (!model.visible) return new haxeon.ui.widgets.layout.Spacer(key, LayoutAxis.fixed(0), LayoutAxis.fixed(0)).build(context);
		var selected = model.selected();
		if (selected == null) return new Text("No sidebar modes").build(context);
		var items:Array<TabItem> = [];
		for (mode in model.modes) if (mode.visible && (!activeOnly || mode.id == selected.id))
			items.push(new TabItem(mode.id, mode.label, new SidebarPage(mode), true, iconProvider == null ? null : iconProvider(mode.id)));
		var options = new TabsOptions();
		options.selectionMode = TabsSelectionMode.Controlled;
		options.style = new LayoutStyle();
		options.style.width = LayoutAxis.stretch(); options.style.height = LayoutAxis.grow();
		options.style.childGap = context.theme.tokens.spacingMedium;
		options.style.clipHorizontal = true;
		// The tab stack must shrink its page to the available height. Vertical
		// clipping here makes Clay treat the whole stack as scroll content and
		// leaves the page at its intrinsic height instead of sizing its viewport.
		// Each destination owns its vertical clipping and scrolling.
		var actions:Null<SidebarHeaderActions> = null;
		if (headerActions != null) {
			var content = headerActions(selected.id);
			if (content != null) { actions = new SidebarHeaderActions(content); options.headerTrailing = actions; }
		}
		var tabs = Tabs.withOptions(key, items, selected.id, onSelect, options);
		var node = tabs.build(context);
		if (actions != null && actions.node != null && headerActionsVisible != null)
			actions.node.layout.style.visible = headerActionsVisible(node);
		node.onResolved(function(bounds) model.rememberWidth(bounds.width));
		return node;
	}
}

private class SidebarPage implements View {
	final mode:SidebarMode;
	public function new(mode:SidebarMode) this.mode = mode;
	public function build(context:BuildContext):RenderNode return mode.provider().build(context);
}

private class SidebarHeaderActions implements View {
	final child:View;
	public var node(default, null):Null<RenderNode>;
	public function new(child:View) this.child = child;
	public function build(context:BuildContext):RenderNode {
		node = child.build(context);
		return node;
	}
}
