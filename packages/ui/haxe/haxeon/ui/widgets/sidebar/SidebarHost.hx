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
	public function new(key:String, model:SidebarModel, onSelect:String->Void, ?iconProvider:String->Null<haxeon.ui.icons.IconName>) {
		this.iconProvider = iconProvider;
		this.key = key; this.model = model; this.onSelect = onSelect;
	}
	public function build(context:BuildContext):RenderNode {
		if (!model.visible) return new haxeon.ui.widgets.layout.Spacer(key, LayoutAxis.fixed(0), LayoutAxis.fixed(0)).build(context);
		var items:Array<TabItem> = [];
		for (mode in model.modes) if (mode.visible)
			items.push(new TabItem(mode.id, mode.label, new SidebarPage(mode), true, iconProvider == null ? null : iconProvider(mode.id)));
		var selected = model.selected();
		if (selected == null) return new Text("No sidebar modes").build(context);
		var options = new TabsOptions();
		options.selectionMode = TabsSelectionMode.Controlled;
		options.style = new LayoutStyle();
		options.style.width = LayoutAxis.grow(); options.style.height = LayoutAxis.grow();
		var node = Tabs.withOptions(key, items, selected.id, onSelect, options).build(context);
		node.onResolved(function(bounds) model.rememberWidth(bounds.width));
		return node;
	}
}

private class SidebarPage implements View {
	final mode:SidebarMode;
	public function new(mode:SidebarMode) this.mode = mode;
	public function build(context:BuildContext):RenderNode return mode.provider().build(context);
}
