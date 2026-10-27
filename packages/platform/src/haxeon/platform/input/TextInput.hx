package haxeon.platform.input;

import haxeon.platform.BindingError;
import haxeon.platform.Surface;
import haxeon.platform.Window;
import haxeon.platform.input.TextInputState;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.Result;

/** Synchronizes managed text-input state and visibility with the platform IME. */
class TextInput {
	public static function update(surface:Surface, state:TextInputState):Void {
		NativeKit.nk_surface_set_text_input_state_checked(surfaceTarget(surface), checkedState(state).nativeValue());
	}

	public static function updateWindow(window:Window, state:TextInputState):Void {
		if (window == null) throw BindingError.invalidArgument("TextInput.updateWindow", "Window cannot be null");
		NativeKit.nk_surface_set_text_input_state_checked(new Handle(window.nativeHandle().rawValue()), checkedState(state).nativeValue());
	}

	/** Returns the backend result so callers can handle unsupported IME backends. */
	public static function updateResult(surface:Surface, state:TextInputState):Result
		return NativeKit.nk_surface_set_text_input_state(surfaceTarget(surface), checkedState(state).nativeValue());

	/** Publishes packed surface-local selection and composition rectangles. */
	public static function updateGeometryResult(surface:Surface,
		selectionStart:Int, selectionEnd:Int, compositionStart:Int, compositionEnd:Int,
		selectionRects:haxe.io.Bytes, compositionRects:haxe.io.Bytes):Result {
		return NativeKit.nk_surface_set_text_input_geometry(surfaceTarget(surface), selectionStart, selectionEnd,
			compositionStart, compositionEnd, selectionRects, compositionRects);
	}

	public static function setActive(surface:Surface, active:Bool):Void
		NativeKit.nk_surface_set_text_input_active_checked(surfaceTarget(surface), active);

	public static function setWindowActive(window:Window, active:Bool):Void {
		if (window == null) throw BindingError.invalidArgument("TextInput.setWindowActive", "Window cannot be null");
		NativeKit.nk_surface_set_text_input_active_checked(new Handle(window.nativeHandle().rawValue()), active);
	}

	public static function setActiveResult(surface:Surface, active:Bool):Result
		return NativeKit.nk_surface_set_text_input_active(surfaceTarget(surface), active);

	static function surfaceTarget(surface:Surface):Handle {
		if (surface == null) throw BindingError.invalidArgument("TextInput.surfaceTarget", "Surface cannot be null");
		return new Handle(surface.nativeHandle().rawValue());
	}

	static function checkedState(state:TextInputState):TextInputState {
		if (state == null) throw BindingError.invalidArgument("TextInput.checkedState", "State cannot be null");
		return state;
	}
}
