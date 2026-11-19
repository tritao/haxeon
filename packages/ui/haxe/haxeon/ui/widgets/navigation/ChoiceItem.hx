package haxeon.ui.widgets.navigation;

/** One option in a ChoiceList; `depth` indents nested options. */
typedef ChoiceItem = {
	id:String,
	label:String,
	?detail:String,
	?depth:Int
};
