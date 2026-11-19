package haxeon.ui.widgets.navigation;

import haxeon.ui.core.View;

/** One screen in a NavigationStack: a stable id and a builder for its content. */
typedef NavigationEntry = {
	id:String,
	build:Void->View
};
