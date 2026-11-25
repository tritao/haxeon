package haxeon.ui.core;

/** Normalized event names routed within the Haxe widget tree. */
class UiEventKind {
	/** The pointer moved, over the widget or while it holds the pointer captured. */
	public static inline var PointerMove:String = "pointerMove";

	/** A button was pressed or a touch began. */
	public static inline var PointerDown:String = "pointerDown";

	/** A button was released or a touch ended. */
	public static inline var PointerUp:String = "pointerUp";

	/** A press and release on the same widget, sent to the widget pressed. */
	public static inline var Click:String = "click";

	/** A wheel or touchpad scroll, by `deltaX` and `deltaY`. */
	public static inline var Scroll:String = "scroll";

	/** A key was pressed, sent to the focused widget. */
	public static inline var KeyDown:String = "keyDown";

	/** A key was released. */
	public static inline var KeyUp:String = "keyUp";

	/** A held key repeated. */
	public static inline var KeyRepeat:String = "keyRepeat";

	/** The focused widget was activated from the keyboard, by Enter or Space: what a click does for a pointer. */
	public static inline var Activate:String = "activate";

	/** Text was typed, with the text in `text`. */
	public static inline var TextInput:String = "textInput";

	/** An input method changed the text it is composing, before committing it with `TextInput`. */
	public static inline var TextEdit:String = "textEdit";

	/** The pointer came over the widget. */
	public static inline var HoverEnter:String = "hoverEnter";

	/** The pointer left the widget. */
	public static inline var HoverLeave:String = "hoverLeave";

	/** The widget became the focused one. */
	public static inline var Focus:String = "focus";

	/** The window lost focus while the widget held it; its focus comes back with the window's. */
	public static inline var FocusLost:String = "focusLost";

	/** The widget stopped being the focused one. */
	public static inline var Blur:String = "blur";

	/** The pointer sequence ended without a release, as when the window loses focus or a gesture takes it over. */
	public static inline var PointerCancel:String = "pointerCancel";

	/** Assistive technology asked to set the widget's value. */
	public static inline var AccessibilitySetValue:String = "accessibilitySetValue";

	/** Assistive technology asked to select a range of the widget's text. */
	public static inline var AccessibilitySetSelection:String = "accessibilitySetSelection";

	/** Assistive technology asked to increase the widget's value, as by a slider step. */
	public static inline var AccessibilityIncrement:String = "accessibilityIncrement";

	/** Assistive technology asked to decrease the widget's value. */
	public static inline var AccessibilityDecrement:String = "accessibilityDecrement";

	/** Assistive technology asked the widget to move to its next item or page. */
	public static inline var AccessibilityMoveNext:String = "accessibilityMoveNext";

	/** Assistive technology asked the widget to move to its previous item or page. */
	public static inline var AccessibilityMovePrevious:String = "accessibilityMovePrevious";
}
