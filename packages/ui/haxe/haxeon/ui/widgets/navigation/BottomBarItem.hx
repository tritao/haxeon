package haxeon.ui.widgets.navigation;

import haxeon.ui.icons.IconName;

/** One destination in a BottomBar; `badge` above zero shows a count. */
typedef BottomBarItem = {
	id:String,
	icon:IconName,
	label:String,
	?badge:Int
};
