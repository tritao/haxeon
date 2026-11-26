package haxeon.ui.semantics;

import haxeon.ui.core.UiEvent;

import haxeon.ui.semantics.Semantics;
/** Decoded platform accessibility request routed to a Haxe semantic target. */
class AccessibilityRequest {
	/** Activate the widget, as a click would. */
	public static inline var Activate = 1;

	/** Move keyboard focus to it. */
	public static inline var Focus = 2;

	/** Take keyboard focus away from it. */
	public static inline var ClearFocus = 3;

	/** Replace its value. */
	public static inline var SetValue = 4;

	/** Change its text selection. */
	public static inline var SetSelection = 5;

	/** Step its value up. */
	public static inline var Increment = 6;

	/** Step its value down. */
	public static inline var Decrement = 7;

	/** Scroll it forward a page. */
	public static inline var ScrollForward = 8;

	/** Scroll it back a page. */
	public static inline var ScrollBackward = 9;

	/** Move to its next item. */
	public static inline var MoveNext = 10;

	/** Move to its previous item. */
	public static inline var MovePrevious = 11;

	/** Toggle it. */
	public static inline var Toggle = 12;

	/** Select it. */
	public static inline var Select = 13;

	/** Deselect it. */
	public static inline var Deselect = 14;

	/** Expand it. */
	public static inline var Expand = 15;

	/** Collapse it. */
	public static inline var Collapse = 16;

	/** Dismiss it. */
	public static inline var Dismiss = 17;

	/** Open its context menu. */
	public static inline var ShowContextMenu = 18;

	/** Scroll it into view. */
	public static inline var ScrollIntoView = 19;

	/** The request's code, one of the constants above. */
	public final action:Int;

	/** The action the target must support for the request to apply. */
	public final capability:AccessibilityAction;

	/** The UI event it is delivered as, or empty for focus requests. */
	public final kind:String;

	/** The new value, for `SetValue`. */
	public final value:Null<String>;

	/** Where the new selection starts, for `SetSelection`. */
	public final selectionStart:Int;

	/** Where it ends. */
	public final selectionEnd:Int;

	/** How many steps to move, for increments and decrements; one or less means one. */
	public final granularity:Int;

	function new(action:Int, capability:AccessibilityAction, kind:String, value:Null<String>,
			selectionStart:Int, selectionEnd:Int, granularity:Int) {
		this.action = action;
		this.capability = capability;
		this.kind = kind;
		this.value = value;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
		this.granularity = granularity;
	}

	/** Decodes a platform request, or returns null for an unknown `action`. */
	public static function create(action:Int, value:Null<String>, selectionStart:Int,
			selectionEnd:Int, granularity:Int):Null<AccessibilityRequest> {
		var capability:AccessibilityAction;
		var kind:String;
		switch (action) {
			case Activate: capability = AccessibilityAction.Activate;
				kind = UiEventKind.Activate;
			case Focus, ClearFocus: capability = AccessibilityAction.Focus;
				kind = "";
			case SetValue: capability = AccessibilityAction.SetValue;
				kind = UiEventKind.AccessibilitySetValue;
			case SetSelection: capability = AccessibilityAction.SetSelection;
				kind = UiEventKind.AccessibilitySetSelection;
			case Increment: capability = AccessibilityAction.Increment;
				kind = UiEventKind.AccessibilityIncrement;
			case Decrement: capability = AccessibilityAction.Decrement;
				kind = UiEventKind.AccessibilityDecrement;
			case ScrollForward: capability = AccessibilityAction.ScrollForward;
				kind = UiEventKind.Scroll;
			case ScrollBackward: capability = AccessibilityAction.ScrollBackward;
				kind = UiEventKind.Scroll;
			case MoveNext: capability = AccessibilityAction.MoveNext;
				kind = UiEventKind.AccessibilityMoveNext;
			case MovePrevious: capability = AccessibilityAction.MovePrevious;
				kind = UiEventKind.AccessibilityMovePrevious;
			case Toggle: capability = AccessibilityAction.Toggle;
				kind = UiEventKind.Activate;
			case Select: capability = AccessibilityAction.Select;
				kind = UiEventKind.Activate;
			case Deselect: capability = AccessibilityAction.Deselect;
				kind = UiEventKind.Activate;
			case Expand: capability = AccessibilityAction.Expand;
				kind = UiEventKind.Activate;
			case Collapse: capability = AccessibilityAction.Collapse;
				kind = UiEventKind.Activate;
			case Dismiss: capability = AccessibilityAction.Dismiss;
				kind = UiEventKind.Activate;
			case ShowContextMenu: capability = AccessibilityAction.ShowContextMenu;
				kind = UiEventKind.Activate;
			case ScrollIntoView: capability = AccessibilityAction.ScrollIntoView;
				kind = UiEventKind.Scroll;
			default: return null;
		}
		return new AccessibilityRequest(action, capability, kind, value,
			selectionStart, selectionEnd, granularity);
	}
}

/** Selection/value details attached to a routed accessibility event. */
class AccessibilityActionData {
	/** The request's code, one of AccessibilityRequest's constants. */
	public final action:Int;

	/** Where the new selection starts, for a selection request. */
	public final selectionStart:Int;

	/** Where it ends. */
	public final selectionEnd:Int;

	/** How many steps to move; one or less means one. */
	public final granularity:Int;

	/** The details of request `action`. */
	public function new(action:Int, selectionStart:Int, selectionEnd:Int, granularity:Int) {
		this.action = action;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
		this.granularity = granularity;
	}
}
