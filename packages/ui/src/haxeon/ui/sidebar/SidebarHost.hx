package haxeon.ui.sidebar;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.View;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.text.Text;

import haxeon.ui.sidebar.SidebarModel;
/** One content-owned tab strip; inactive providers never build. */
class SidebarHost implements View {
	final key:String;
	final model:SidebarModel;
	final onSelect:String->Void;
	final iconProvider:Null<String->Null<haxeon.ui.icons.IconName>>;
	final activeOnly:Bool;
	/** Optional fixed header actions for the active destination. */
	public final headerActions:Null<String->Null<View>>;

	/**
	 * A sidebar showing `model`'s selected destination under a strip of its destinations, calling `onSelect` with the
	 * one the user picks; `iconProvider` gives each an icon.
	 */
	public function new(key:String, model:SidebarModel, onSelect:String->Void,
			?iconProvider:String->Null<haxeon.ui.icons.IconName>, activeOnly:Bool = false,
			?headerActions:String->Null<View>) {
		this.activeOnly = activeOnly;
		this.iconProvider = iconProvider;
		this.key = key;
		this.model = model;
		this.onSelect = onSelect;
		this.headerActions = headerActions;
	}
	public function build(context:BuildContext):ViewRoot {
		if (!model.visible) return new haxeon.ui.widgets.layout.Spacer(key, LayoutAxis.fixed(0),
			LayoutAxis.fixed(0)).build(context);
		var selected = model.selected();
		if (selected == null) return new Text("No sidebar modes").build(context);
		var items:Array<TabItem> = [];
		for (mode in model.modes) if (mode.visible && (!activeOnly || mode.id == selected.id))
			items.push(new TabItem(mode.id, mode.label, new SidebarPage(mode), true,
			iconProvider == null ? null : iconProvider(mode.id)));
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.height = LayoutAxis.grow();
		style.clipHorizontal = true;
		// The tab stack must shrink its page to the available height. Vertical
		// clipping here would make the whole stack scroll content and leave
		// the page at its intrinsic height instead of sizing its viewport.
		// Each destination owns its vertical clipping and scrolling.
		var tabs = new Tabs(key, items, selected.id, onSelect, style, selectionMode: TabsSelectionMode.Controlled,
			headerTrailing: headerActions == null ? null : headerActions(selected.id));
		var modifier = new RootModifier();
		modifier.onResolved(bounds -> model.rememberWidth(bounds.width));
		return context.build(tabs, modifier);
	}
}

private class SidebarPage implements View {
	final mode:SidebarMode;
	public function new(mode:SidebarMode) this.mode = mode;
	public function build(context:BuildContext):ViewRoot return mode.provider().build(context);
}
