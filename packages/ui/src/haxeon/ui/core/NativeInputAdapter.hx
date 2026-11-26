package haxeon.ui.core;

import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import haxeon.ui.core.RenderNode.CursorShape as UiCursorShape;
import haxeon.ui.core.UiEvent;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitTypes.NativeCursorShape;

/** Routes decoded NativeKit window input into one Haxe UiContext. */
class NativeInputAdapter {
	final context:UiContext;
	final source:Handle;
	/** Surface source for accessibility and transactional text edits. */
	final accessibilitySource:Handle;
	final cursor:NativeCursorController;
	final window:WindowHandle;
	var attachedEvents:Null<EventPump>;
	var eventSubscription:Null<EventSubscription>;
	var keySubscription:Null<EventSubscription>;
	var redrawOnInput = false;
	final eventListener:PlatformEvent->Void;
	/**
		Phone form-factor override (EXOSUIT_FORM_FACTOR=phone): the left mouse button is delivered as touch pointer 0, so
		the phone gestures work with a mouse. Other buttons are dropped, and a move without the button down is not a touch.
	**/
	public static var mouseAsTouch:Bool = false;
	var mouseTouchDown:Bool = false;
	/** Converts window logical coordinates into application layout coordinates. */
	public var coordinateScale:Float = 1.0;
	var pointerX:Float;
	var pointerY:Float;
	var pointerModifiers:UiModifier = UiModifier.empty();
	var heldModifierKeys:Int = 0;

	/**
	 * An adapter feeding the input of the window `source` to `context`, and accessibility requests from
	 * `accessibilitySource` (the window itself by default); `attach` connects it to the event pump. Throws without a
	 * context or with an invalid window.
	 */
	public function new(context:UiContext, source:Handle, ?accessibilitySource:Handle) {
		if (context == null || !source.isValid())
			throw "Native input requires a UI context and window handle";
		this.context = context;
		this.source = source;
		this.accessibilitySource = accessibilitySource == null ? source : accessibilitySource;
		window = new WindowHandle(source.rawValue);
		cursor = new NativeCursorController(source);
		attachedEvents = null;
		eventSubscription = null;
		eventListener = function(event) {
			switch event {
				case Key(_, _, _, _, _): return;
				case _:
			}
			if (consume(event) && redrawOnInput)
				context.requestFrameIfDirty();
		};
		pointerX = 0.0;
		pointerY = 0.0;
	}

	/** Subscribes this adapter to the runtime's shared event pump. */
	public function attach(events:EventPump, redrawOnInput:Bool = false):Void {
		if (events == null)
			throw "Native input requires a NativeKit event pump";
		if (events.isDisposed())
			throw "Native input cannot attach to a disposed NativeKit event pump";
		if (attachedEvents == events) {
			this.redrawOnInput = redrawOnInput;
			return;
		}
		detach();
		this.redrawOnInput = redrawOnInput;
		eventSubscription = events.listen(eventListener);
		keySubscription = events.listenSource(source, function(event) return switch event {
			case Key(_, key, scancode, action, modifiers):
				var handled = dispatchKey(key, scancode, action, modifiers);
				if (this.redrawOnInput) context.requestFrameIfDirty();
				handled;
			case _: false;
		});
		attachedEvents = events;
		context.setPointerCaptureHandler(function(captured) {
			try {
				// NativeKit exposes physical capture through the window's pointer
				// mode. Logical capture remains authoritative when a backend does
				// not support the platform operation.
				NativeKit.nk_window_set_cursor_mode_checked(window, captured ? CursorMode.Captured : CursorMode.Normal);
			} catch (_:Dynamic) {
				// Unsupported capture must not interrupt logical event routing.
			}
		});
		context.setCursorHandler(function(shape) {
			cursor.apply(shape);
		});
	}

	/** Stops routing events from the attached pump. */
	public function detach():Void {
		pointerModifiers = UiModifier.empty();
		heldModifierKeys = 0;
		if (attachedEvents != null) {
			if (keySubscription != null)
				keySubscription.dispose();
			keySubscription = null;
			if (eventSubscription != null)
				eventSubscription.dispose();
			eventSubscription = null;
			attachedEvents = null;
			context.setPointerCaptureHandler(null);
			context.setCursorHandler(null);
			cursor.reset();
		}
	}

	/** Consumes recognized input for this window; other event kinds/sources pass through. */
	public function consume(event:PlatformEvent):Bool {
		if (event == null)
			return false;
		return switch (event) {
			case ClipboardText(_, _, _) if (context.clipboard.consume(event)):
				true;
			case PointerMove(eventSource, x, y) if (matches(eventSource)):
				pointerX = x;
				pointerY = y;
				if (mouseAsTouch) {
					if (mouseTouchDown)
						context.pointerMove(x / coordinateScale, y / coordinateScale, pointerModifiers,
							touchPointerId(0),
							new UiTouchData(TouchTool.Finger, 1.0, 0.0, 0.0));
					return true;
				}
				context.pointerMove(x / coordinateScale, y / coordinateScale, pointerModifiers);
				true;
			case PointerButton(eventSource, button, action, modifiers, x, y) if (matches(eventSource)):
				pointerX = x;
				pointerY = y;
				snapshotModifiers(UiModifier.fromRaw(modifiers.rawValue));
				if (mouseAsTouch) {
					if (button.rawValue != NativeKitTypes.PointerButton.Left.rawValue) return true;
					var touchData = new UiTouchData(TouchTool.Finger, action == InputAction.Press ? 1.0 : 0.0, 0.0,
						0.0);
					if (action == InputAction.Press) {
						mouseTouchDown = true;
						context.pointerDown(x / coordinateScale, y / coordinateScale, 0,
							UiModifier.fromRaw(modifiers.rawValue),
							touchPointerId(0), touchData);
					} else if (action == InputAction.Release) {
						mouseTouchDown = false;
						context.pointerUp(x / coordinateScale, y / coordinateScale, 0,
							UiModifier.fromRaw(modifiers.rawValue),
							touchPointerId(0), touchData);
					}
					return true;
				}
				if (action == InputAction.Press)
					context.pointerDown(x / coordinateScale, y / coordinateScale, button.rawValue,
						UiModifier.fromRaw(modifiers.rawValue));
				else if (action == InputAction.Release)
					context.pointerUp(x / coordinateScale, y / coordinateScale, button.rawValue,
						UiModifier.fromRaw(modifiers.rawValue));
				action == InputAction.Press || action == InputAction.Release;
			case PointerScroll(eventSource, deltaX, deltaY) if (matches(eventSource)):
				context.scroll(pointerX / coordinateScale, pointerY / coordinateScale, deltaX / coordinateScale,
					deltaY / coordinateScale, pointerModifiers);
				true;
			case PointerEnter(eventSource, entered) if (matches(eventSource)):
				if (!entered)
					context.pointerLeave();
				else if (context.events.hasCapturedPointer()) {
					// A release outside the window may be missed when native capture is
					// unavailable. Reconcile the drag against the platform button state.
					var button = context.events.capturedPointerButton();
					try {
						if (button != null)
							context.pointerReenter(NativeKit.nk_pointer_button_get_state_checked(window,
								NativeKitTypes.NativeKitTypesEnumDecoders.decodePointerButton(button))
								== InputAction.Press, pointerX / coordinateScale, pointerY / coordinateScale);
					} catch (_:Dynamic) {}
				}
				true;
			case WindowStateChanged(eventSource, flags) if (matches(eventSource)):
				if (!flags.contains(WindowStateFlags.Active)) {
					pointerModifiers = UiModifier.empty();
					heldModifierKeys = 0;
					context.windowFocusLost();
				} else context.windowFocusGained();
				true;
			case PlatformEvent.Key(eventSource, key, scancode, action, modifiers)
				if (matches(eventSource)):
				dispatchKey(key, scancode, action, modifiers);
				keyKind(action) != null;
			case TextInput(eventSource, codepoint) if (matchesText(eventSource)):
				context.text(UiEventKind.TextInput, fromCodepoint(codepoint), codepoint);
				true;
			case TextEdit(eventSource, edit) if (matchesText(eventSource)):
				context.text(UiEventKind.TextEdit, edit.text, edit);
				true;
			case AccessibilityAction(eventSource, nodeId, action, value, selectionStart,
				selectionEnd, granularity) if (eventSource == accessibilitySource):
				// A code newer than this build names no action, and nothing handles it.
				var request = haxeon.ui.semantics.AccessibilityRequest.AccessibilityRequestAction.fromRaw(action);
				if (request != null)
					context.accessibilityAction(nodeId, request, value, selectionStart, selectionEnd, granularity);
				true;
			case Touch(eventSource, pointerId, action, tool, modifiers, x, y, pressure, tiltX, tiltY)
				if (matches(eventSource)):
				pointerX = x;
				pointerY = y;
				var routedId = touchPointerId(pointerId);
				var data = new UiTouchData(tool, pressure, tiltX, tiltY);
				if (action == TouchAction.Begin)
					context.pointerDown(x / coordinateScale, y / coordinateScale, 0,
						UiModifier.fromRaw(modifiers.rawValue), routedId, data);
				else if (action == TouchAction.Move)
					context.pointerMove(x / coordinateScale, y / coordinateScale,
						UiModifier.fromRaw(modifiers.rawValue), routedId, data);
				else if (action == TouchAction.End)
					context.pointerUp(x / coordinateScale, y / coordinateScale, 0,
						UiModifier.fromRaw(modifiers.rawValue), routedId, data);
				else if (action == TouchAction.Cancel)
					context.pointerCancel(routedId, x / coordinateScale, y / coordinateScale,
						UiModifier.fromRaw(modifiers.rawValue), data);
				action == TouchAction.Begin || action == TouchAction.Move || action == TouchAction.End
					|| action == TouchAction.Cancel;
			case _:
				false;
		}
	}

	/** Mouse move/wheel events omit modifiers; retain ordered window input state. */
	function snapshotModifiers(modifiers:UiModifier):Void {
		pointerModifiers = modifiers;
		for (index in 0...4)
			if ((modifiers.rawValue & (1 << index)) == 0)
				heldModifierKeys &= ~((1 << index) | (1 << (index + 4)));
	}

	function dispatchKey(key:nativekit.ffi.NativeKitTypes.Key, scancode:Int, action:InputAction,
			modifiers:Modifiers):Bool {
		var kind = keyKind(action);
		if (kind == null)
			return false;
		var keyCode = key.rawValue;
		var uiModifiers = UiModifier.fromRaw(modifiers.rawValue);
		updateKeyModifiers(keyCode, action, uiModifiers);
		return context.key(kind, key, uiModifiers, scancode);
	}

	function updateKeyModifiers(key:Int, action:InputAction, modifiers:UiModifier):Void {
		// NativeKit normalizes left/right Shift, Control, Alt and Super to 340..347.
		// GTK snapshots precede the key action; other hosts may snapshot afterward.
		if (key < 340 || key > 347) {
			snapshotModifiers(modifiers);
			return;
		}
		var index = key - 340;
		var held = 1 << index;
		if (action == InputAction.Release) heldModifierKeys &= ~held;
		else heldModifierKeys |= held;
		var modifier = UiModifier.fromRaw(1 << (index & 3));
		var pair = modifier.rawValue | (modifier.rawValue << 4);
		pointerModifiers = modifiers;
		if ((heldModifierKeys & pair) != 0) pointerModifiers = pointerModifiers.insert(modifier);
		else pointerModifiers = pointerModifiers.remove(modifier);
	}

	function matches(eventSource:Handle):Bool
		return eventSource == source;

	/**
	 * Text events come from the window or the graphics surface that has text input (NativeKit's api.md): Windows
	 * reports the window, the web backend the surface.
	 */
	function matchesText(eventSource:Handle):Bool
		return eventSource == source || eventSource == accessibilitySource;

	static function keyKind(action:InputAction):Null<String> {
		if (action == InputAction.Press)
			return UiEventKind.KeyDown;
		if (action == InputAction.Release)
			return UiEventKind.KeyUp;
		if (action == InputAction.Repeat)
			return UiEventKind.KeyRepeat;
		return null;
	}

	static function touchPointerId(pointerId:Int):Int
		return pointerId | 0x80000000;

	static function fromCodepoint(codepoint:Int):String {
		if (codepoint < 0 || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff))
			codepoint = 0xfffd;
		var bytes = haxe.io.Bytes.alloc(codepoint <= 0x7f ? 1 : codepoint <= 0x7ff ? 2 : codepoint <= 0xffff ? 3 : 4);
		if (bytes.length == 1)
			bytes.set(0, codepoint);
		else if (bytes.length == 2) {
			bytes.set(0, 0xc0 | (codepoint >>> 6));
			bytes.set(1, 0x80 | (codepoint & 0x3f));
		} else if (bytes.length == 3) {
			bytes.set(0, 0xe0 | (codepoint >>> 12));
			bytes.set(1, 0x80 | ((codepoint >>> 6) & 0x3f));
			bytes.set(2, 0x80 | (codepoint & 0x3f));
		} else {
			bytes.set(0, 0xf0 | (codepoint >>> 18));
			bytes.set(1, 0x80 | ((codepoint >>> 12) & 0x3f));
			bytes.set(2, 0x80 | ((codepoint >>> 6) & 0x3f));
			bytes.set(3, 0x80 | (codepoint & 0x3f));
		}
		return bytes.toString();
	}
}

/** Applies UI cursor intent to one NativeKit window with lazy native resources. */
internal class NativeCursorController {
	final window:WindowHandle;
	final cursors:Map<NativeCursorShape, OwnedCursorHandle>;
	var capabilityChecked:Bool;
	var available:Bool;
	var active:UiCursorShape;

	public function new(source:Handle) {
		if (source == null || !source.isValid())
			throw "Native cursor control requires a live window handle";
		window = new WindowHandle(source.rawValue);
		cursors = new Map();
		capabilityChecked = false;
		available = false;
		active = UiCursorShape.Arrow;
	}

	/** Best-effort application; cursor decoration must not break input delivery. */
	public function apply(shape:UiCursorShape):Void {
		if (shape == active)
			return;
		if (shape == UiCursorShape.Arrow) {
			if (available)
				setNativeCursor(CursorHandle.invalid());
			active = UiCursorShape.Arrow;
			return;
		}
		if (!supportsCursor())
			return;

		var key = shape;
		var owner = cursors.get(key);
		if (owner == null || owner.isClosed()) {
			try {
				owner = NativeKit.nk_cursor_create_standard_checked(key);
				cursors.set(key, owner);
			} catch (_:Dynamic) {
				available = false;
				return;
			}
		}
		if (setNativeCursor(owner.borrow()))
			active = shape;
	}

	/** Restores the platform cursor and releases standard cursor resources. */
	public function reset():Void {
		if (active != UiCursorShape.Arrow && available)
			setNativeCursor(CursorHandle.invalid());
		active = UiCursorShape.Arrow;
		var keys:Array<NativeCursorShape> = [];
		for (key in cursors.keys())
			keys.push(key);
		for (key in keys) {
			var owner = cursors.get(key);
			if (owner != null)
				owner.close();
			cursors.remove(key);
		}
	}

	function supportsCursor():Bool {
		if (capabilityChecked)
			return available;
		capabilityChecked = true;
		var capabilities = NativeKit.nk_get_capabilities();
		available = haxe.Int64.compare(haxe.Int64.and(capabilities, Capabilities.cursor()), haxe.Int64.ofInt(0)) != 0;
		return available;
	}

	function setNativeCursor(cursor:CursorHandle):Bool {
		try {
			NativeKit.nk_window_set_cursor_checked(window, cursor);
			return true;
		} catch (_:Dynamic) {
			available = false;
			return false;
		}
	}
}
