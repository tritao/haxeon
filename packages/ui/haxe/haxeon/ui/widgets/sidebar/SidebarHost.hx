package haxeon.ui.widgets.sidebar;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
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
		options.style.width = LayoutAxis.stretch(); options.style.height = LayoutAxis.grow();
		options.style.clipHorizontal = true;
		// The tab stack must shrink its page to the available height. Vertical
		// clipping here makes Clay treat the whole stack as scroll content and
		// leaves the page at its intrinsic height instead of sizing its viewport.
		// Each destination owns its vertical clipping and scrolling.
		var tabs = Tabs.withOptions(key, items, selected.id, onSelect, options);
		var node = context.withScope(new Key(key + "-rail"), function() {
			var state = context.state(context.id("scroll"), new SidebarRailState()).value;
			tabs.transformHeaderStrip = function(strip, buildContext) {
				strip.layout.style.width = LayoutAxis.fit();
				var active:Null<RenderNode> = null;
				for (index in 0...items.length) if (items[index].key == selected.id) active = strip.children[index];
				var style = new LayoutStyle(); style.width = LayoutAxis.stretch();
				var scroll = new ScrollView("sidebar-tabs", new SidebarBuiltView(strip), style, ScrollAxis.Horizontal, state.controller);
				scroll.showScrollbar = false;
				scroll.onScroll = function(event) {
					if (event.deltaX == 0 && state.controller.scrollBy(event.deltaY, 0)) {
						event.preventDefault(); event.stopPropagation();
					}
				};
				var viewport = scroll.build(buildContext);
				// Headers resolve after the scroll metrics, so reveal uses the current range.
				if (active != null) active.onResolved(function(_) {
					if (viewport.resolved == null) return;
					var bounds = viewport.globalBounds();
					if (state.selected == selected.id && state.width == bounds.width) return;
					state.selected = selected.id; state.width = bounds.width;
					var tab:haxeon.ui.ResolvedLayoutItem = cast active.resolved; var next = state.controller.offsetX;
					var viewportGeometry:haxeon.ui.ResolvedLayoutItem = cast viewport.resolved;
					var left = tab.x - viewportGeometry.x;
					if (tab.width > bounds.width || left < next) next = left;
					else if (left + tab.width > next + bounds.width) next = left + tab.width - bounds.width;
					if (state.controller.jumpTo(next, 0)) buildContext.requestLayoutFeedback();
				});
				return viewport;
			};
			return tabs.build(context);
		});
		node.onResolved(function(bounds) model.rememberWidth(bounds.width));
		return node;
	}
}

private class SidebarPage implements View {
	final mode:SidebarMode;
	public function new(mode:SidebarMode) this.mode = mode;
	public function build(context:BuildContext):RenderNode return mode.provider().build(context);
}

private class SidebarBuiltView implements View {
	final node:RenderNode;
	public function new(node:RenderNode) this.node = node;
	public function build(context:BuildContext):RenderNode return node;
}
private class SidebarRailState {
	public final controller = new ScrollController();
	public var selected:String = "";
	public var width:Float = -1;
	public function new() {}
}
