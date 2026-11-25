package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;

/** Optional behavior and presentation settings for an advanced tab strip. */
class TabsOptions {
	/** `Tabs.headerTrailing`: fixed actions beside the scrolling tab strip. */
	public var headerTrailing:Null<haxeon.ui.core.View>;

	/** `Tabs.style`; the default when null. */
	public var style:Null<LayoutStyle>;

	/** `Tabs.selectionMode`: `Local` unless set. */
	public var selectionMode:TabsSelectionMode;

	/** `Tabs.onTabDragStart`. */
	public var onTabDragStart:Null<String->UiEvent->Void>;

	/** `Tabs.onTabDragMove`. */
	public var onTabDragMove:Null<String->UiEvent->Void>;

	/** `Tabs.onTabDragEnd`. */
	public var onTabDragEnd:Null<String->UiEvent->Void>;

	/** `Tabs.onTabDragCancel`. */
	public var onTabDragCancel:Null<String->UiEvent->Void>;

	/** `Tabs.onTabContextMenu`. */
	public var onTabContextMenu:Null<String->UiEvent->Void>;

	/** `Tabs.onTabHeaderBuilt`. */
	public var onTabHeaderBuilt:Null<String->RenderNode->Void>;

	/** Options that change nothing until set. */
	public function new() {
		headerTrailing = null;
		style = null;
		selectionMode = TabsSelectionMode.Local;
		onTabDragStart = null;
		onTabDragMove = null;
		onTabDragEnd = null;
		onTabDragCancel = null;
		onTabHeaderBuilt = null;
		onTabContextMenu = null;
	}
}
