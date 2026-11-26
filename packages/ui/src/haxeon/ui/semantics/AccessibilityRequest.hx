package haxeon.ui.semantics;

import haxeon.ui.core.UiEvent;

import haxeon.ui.semantics.Semantics;
/** What assistive technology asks a node to do; its code is NativeKit's (`nk_accessibility_action`). */
typedef AccessibilityRequestAction = nativekit.ffi.NativeKitTypes.AccessibilityAction;

/** Decoded platform accessibility request routed to a Haxe semantic target. */
class AccessibilityRequest {
	/** What it asks for. */
	public final action:AccessibilityRequestAction;

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

	function new(action:AccessibilityRequestAction, capability:AccessibilityAction, kind:String, value:Null<String>,
			selectionStart:Int, selectionEnd:Int, granularity:Int) {
		this.action = action;
		this.capability = capability;
		this.kind = kind;
		this.value = value;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
		this.granularity = granularity;
	}

	/** The request for `action`, with the capability it needs and the event it is delivered as. */
	public static function create(action:AccessibilityRequestAction, value:Null<String>, selectionStart:Int,
			selectionEnd:Int, granularity:Int):AccessibilityRequest {
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
		}
		return new AccessibilityRequest(action, capability, kind, value,
			selectionStart, selectionEnd, granularity);
	}
}

/** Selection/value details attached to a routed accessibility event. */
class AccessibilityActionData {
	/** What it asks for. */
	public final action:AccessibilityRequestAction;

	/** Where the new selection starts, for a selection request. */
	public final selectionStart:Int;

	/** Where it ends. */
	public final selectionEnd:Int;

	/** How many steps to move; one or less means one. */
	public final granularity:Int;

	/** The details of request `action`. */
	public function new(action:AccessibilityRequestAction, selectionStart:Int, selectionEnd:Int, granularity:Int) {
		this.action = action;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
		this.granularity = granularity;
	}
}
