package haxeon.ui.core;

import nativekit.ffi.NativeKitTypes.TouchTool;

/** Routed event shared by capture, target, and bubble handlers. */
class UiEvent {
	/** What happened: one of `UiEventKind`'s names. */
	public final kind:String;

	/** The widget the event is aimed at: the one under the pointer, or the focused one for keys and text. */
	public final target:WidgetId;

	/** The pointer's x in viewport coordinates, as `globalX`; 0 for keys, text and focus. */
	public final x:Float;

	/** The pointer's y in viewport coordinates, as `globalY`; 0 for keys, text and focus. */
	public final y:Float;

	/** For `Scroll`, how far to scroll horizontally; for an accessibility adjustment, its amount; 0 otherwise. */
	public final deltaX:Float;

	/** For `Scroll`, how far to scroll vertically; for an accessibility adjustment, its amount; 0 otherwise. */
	public final deltaY:Float;

	/** For pointer events, the mouse button: 0 is the primary one. */
	public final button:Int;

	/** For key events and `Activate`, the key code (`UiKey`); 0 otherwise. */
	public final key:Int;

	/** For key events, the key's physical position on the keyboard, whatever its layout. */
	public final scancode:Int;

	/** The modifier keys held when the event happened. */
	public final modifiers:UiModifier;

	/** Which pointer, for touch and pen input with several at once; 0 for the mouse. */
	public final pointerId:Int;

	/** When the platform reported the event, in seconds; negative when unknown. */
	public final timestamp:Float;

	/** For `TextInput`, the text typed; for `TextEdit`, the input method's text being composed. */
	public final text:Null<String>;

	/**
	 * Details particular to the kind: `UiTouchData` for touch, the composition for `TextEdit`, the request for
	 * accessibility events.
	 */
	public final data:Dynamic;
	/** Viewport coordinates retained under the explicit global names. */
	public var globalX(get, never):Float;

	/** The pointer's y in viewport coordinates. */
	public var globalY(get, never):Float;
	/** Coordinates transformed into the currentTarget's local space. */
	public var localX(default, null):Float;

	/** The pointer's y in `currentTarget`'s own coordinates. */
	public var localY(default, null):Float;

	/** The widget whose handler is running now, as the event travels its path. */
	public var currentTarget:Null<WidgetId>;

	/** Where the event is on its path: going down to the target, at it, or coming back up. */
	public var phase:UiEventPhase;

	/**
	 * Whether a handler called `preventDefault`: the widget's built-in response (a text field's typing, a button's
	 * activation) is skipped.
	 */
	public var defaultPrevented(default, null):Bool;

	/** Whether a handler called `markHandled`, which tells the host the UI used the key. */
	public var handled(default, null):Bool = false;

	/** Whether a handler called `stopPropagation`: no widget further along the path sees it. */
	public var propagationStopped(default, null):Bool;

	/** Whether a handler called `stopImmediatePropagation`: no further handler sees it, on this widget either. */
	public var immediatePropagationStopped(default, null):Bool;
	internal var pointerCaptureTarget(default, null):Null<WidgetId>;
	internal var pointerNativeCaptureRequested(default, null):Bool;
	internal var pointerReleaseRequested(default, null):Bool;
	internal var pointerCancelRequested(default, null):Bool;

	/**
	 * An event of `kind` aimed at `target`. The UI context makes these from platform input; a test or a synthetic
	 * gesture can make its own. Throws without a kind or target.
	 */
	public function new(kind:String,
			target:WidgetId,
			x:Float = 0.0,
			y:Float = 0.0,
			deltaX:Float = 0.0,
			deltaY:Float = 0.0,
			button:Int = 0,
			key:Int = 0,
			modifiers:UiModifier = UiModifier.empty(),
			text:Null<String> = null,
			data:Dynamic = null,
			scancode:Int = 0,
			pointerId:Int = 0,
			timestamp:Float = -1.0) {
		if (kind == null || kind.length == 0 || target == null) throw "Routed events require a kind and target";
		this.kind = kind;
		this.target = target;
		this.x = x;
		this.y = y;
		this.deltaX = deltaX;
		this.deltaY = deltaY;
		this.button = button;
		this.key = key;
		this.scancode = scancode;
		this.modifiers = modifiers;
		this.pointerId = pointerId;
		this.timestamp = timestamp;
		this.text = text;
		this.data = data;
		localX = x;
		localY = y;
		currentTarget = null;
		phase = UiEventPhase.Target;
		defaultPrevented = false;
		propagationStopped = false;
		immediatePropagationStopped = false;
		pointerCaptureTarget = null;
		pointerNativeCaptureRequested = false;
		pointerReleaseRequested = false;
		pointerCancelRequested = false;
	}

	inline function get_globalX():Float return x;

	inline function get_globalY():Float return y;

	@:allow(haxeon.ui.core.EventDispatcher) function setCurrentTarget(node:RenderNode):Void {
		if (node == null) throw "Routed events require a current target";
		currentTarget = node.id;
		var geometry = node.resolved;
		if (geometry == null || !geometry.canMapViewport()) {
			localX = globalX;
			localY = globalY;
		} else {
			localX = geometry.viewportToLocalX(globalX, globalY);
			localY = geometry.viewportToLocalY(globalX, globalY);
		}
	}

	/**
	 * Stops the event at the current widget: the rest of its handlers run, but no widget further along the path sees
	 * it.
	 */
	public function stopPropagation():Void propagationStopped = true;

	/** Stops remaining handlers on the current node and all later propagation. */
	public function stopImmediatePropagation():Void {
		immediatePropagationStopped = true;
		propagationStopped = true;
	}

	/** Skips the widget's built-in response to the event, such as a key's default action. */
	public function preventDefault():Void defaultPrevented = true;

	/** Lets the host know the UI used this key while preserving UI default actions. */
	public function markHandled():Void handled = true;

	/** Routes this pointer sequence to the current handler; native capture is optional. */
	public function capturePointer(requestNativeCapture:Bool = true):Void {
		pointerCaptureTarget = currentTarget == null ? target : currentTarget;
		pointerNativeCaptureRequested = requestNativeCapture;
		pointerReleaseRequested = false;
	}

	/** Releases explicit pointer capture after the current event finishes dispatching. */
	public function releasePointer():Void {
		pointerCaptureTarget = null;
		pointerReleaseRequested = true;
	}

	/** Requests cancellation of pointer capture owned by this event's target. */
	public function cancelPointerCapture():Void pointerCancelRequested = true;
}

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

/** Position of the current delivery in a routed event. Direct notifications use Target. */
enum UiEventPhase {
	/** Going down from the root to the target: an ancestor sees the event before the widget does. */
	Capture;

	/** At the target itself. */
	Target;

	/** Coming back up from the target to the root. */
	Bubble;
}

/** Modifier bit values shared with NativeKit input events. */
enum abstract UiModifier(Int) implements Flags {
	/** Either Shift key. */
	var Shift = 1 << 0;

	/** Either Control key. */
	var Control = 1 << 1;

	/** Either Alt (Option) key. */
	var Alt = 1 << 2;

	/** Either Super key: Command on macOS, the Windows key on Windows. */
	var Super = 1 << 3;

	/** Caps Lock is on. */
	var CapsLock = 1 << 4;

	/** Num Lock is on. */
	var NumLock = 1 << 5;
}

/** Platform touch details preserved on normalized pointer events. */
class UiTouchData {
	/** What touched: a finger, a pen or an eraser. */
	public final tool:TouchTool;

	/** How hard, normalized from 0 to 1; the platform's default when the device does not report it. */
	public final pressure:Float;

	/** A pen's tilt around the x axis, in the platform's normalized units; 0 when not reported. */
	public final tiltX:Float;

	/** A pen's tilt around the y axis, in the platform's normalized units; 0 when not reported. */
	public final tiltY:Float;

	/** Touch details as the platform reports them. */
	public function new(tool:TouchTool, pressure:Float, tiltX:Float, tiltY:Float) {
		this.tool = tool;
		this.pressure = pressure;
		this.tiltX = tiltX;
		this.tiltY = tiltY;
	}
}
