package haxeon.ui.core;


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
