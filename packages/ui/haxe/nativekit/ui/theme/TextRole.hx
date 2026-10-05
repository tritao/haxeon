package nativekit.ui.theme;

import nativekit.ui.widgets.controls.Button;


/** Semantic typography roles resolved by the NativeKit UI framework. */
enum abstract TextRole(Int) from Int to Int {
	var Body = 0;
	var Heading = 1;
	var Label = 2;
	var Caption = 3;
	var Button = 4;
}
