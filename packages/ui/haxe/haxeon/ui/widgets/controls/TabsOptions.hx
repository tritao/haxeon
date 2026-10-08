package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;

/** Optional behavior and presentation settings for an advanced tab strip. */
class TabsOptions {
	public var headerTrailing:Null<haxeon.ui.core.View>;
	public var style:Null<LayoutStyle>;
	public var selectionMode:TabsSelectionMode;
	public var onTabDragStart:Null<String->UiEvent->Void>;
	public var onTabDragMove:Null<String->UiEvent->Void>;
	public var onTabDragEnd:Null<String->UiEvent->Void>;
	public var onTabDragCancel:Null<String->UiEvent->Void>;
	public var onTabContextMenu:Null<String->UiEvent->Void>;
	public var onTabHeaderBuilt:Null<String->RenderNode->Void>;

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
