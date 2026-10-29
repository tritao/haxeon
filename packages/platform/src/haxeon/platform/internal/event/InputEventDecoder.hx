package haxeon.platform.internal.event;

import haxeon.platform.BindingError;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.input.TextEdit as PlatformTextEdit;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.EventSnapshot;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.GamepadAxisEvent;
import nativekit.ffi.NativeKitTypes.GamepadButtonEvent;
import nativekit.ffi.NativeKitTypes.JoystickAxisEvent;
import nativekit.ffi.NativeKitTypes.JoystickButtonEvent;
import nativekit.ffi.NativeKitTypes.JoystickHatEvent;
import nativekit.ffi.NativeKitTypes.KeyEvent;
import nativekit.ffi.NativeKitTypes.PointerButtonEvent;
import nativekit.ffi.NativeKitTypes.PointerMoveEvent;
import nativekit.ffi.NativeKitTypes.PointerScrollEvent;
import nativekit.ffi.NativeKitTypes.TextEditEvent;
import nativekit.ffi.NativeKitTypes.TextInputEvent;
import nativekit.ffi.NativeKitTypes.TouchEvent;

class InputEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent> return switch c.kind {
		case EventKind.Key: EventBytes.requireSize(c.data,16); var v:KeyEvent=c.data; Key(c.source,v.get_key(),v.get_scancode(),v.get_action(),v.get_modifiers());
		case EventKind.TextInput: EventBytes.requireSize(c.data,8); var v:TextInputEvent=c.data; TextInput(c.source,v.get_codepoint());
		case EventKind.TextEdit:
			EventBytes.requireMinimumSize(c.data,48); var v:TextEditEvent=c.data;
			var text=EventBytes.readUtf8Slice(c.data,v.get_text_offset(),v.get_text_length(),48);
			var affinity = v.get_selection_affinity();
			var history = v.get_history_kind();
			if (affinity > 4 || history > 6)
				throw BindingError.invalidData("InputEventDecoder.decode", "NativeKit text edit payload has invalid metadata");
			TextEdit(c.source,new PlatformTextEdit(v.get_action(),text,v.get_replace_start(),v.get_replace_end(),v.get_selection_start(),v.get_selection_end(),v.get_composition_start(),v.get_composition_end(),affinity,history));
		case EventKind.AccessibilityAction:
			EventBytes.requireMinimumSize(c.data,32);
			var nodeId = EventBytes.readU32(c.data, 0);
			var action = EventBytes.readU32(c.data, 4);
			var valueOffset = EventBytes.readU32(c.data, 8);
			var valueLength = EventBytes.readU32(c.data, 12);
			var selectionStart = EventBytes.readU32(c.data, 16);
			var selectionEnd = EventBytes.readU32(c.data, 20);
			var granularity = EventBytes.readU32(c.data, 24);
			if (nodeId <= 0 || action < 1 || action > 11 || EventBytes.readU32(c.data, 28) != 0)
				throw BindingError.invalidData("InputEventDecoder.decode", "NativeKit accessibility action payload has invalid fields");
			var value = EventBytes.readUtf8Slice(c.data, valueOffset, valueLength, 32);
			if (valueLength > 0 && (valueOffset + valueLength >= c.data.length ||
				c.data.get(valueOffset + valueLength) != 0))
				throw BindingError.invalidData("InputEventDecoder.decode", "NativeKit accessibility action value is not NUL-terminated");
			AccessibilityAction(c.source, nodeId, action, value, selectionStart,
				selectionEnd, granularity);
		case EventKind.PointerMove: EventBytes.requireSize(c.data,16); var v:PointerMoveEvent=c.data; PointerMove(c.source,v.get_x(),v.get_y());
		case EventKind.PointerButton: EventBytes.requireSize(c.data,32); var v:PointerButtonEvent=c.data; PointerButton(c.source,v.get_button(),v.get_action(),v.get_modifiers(),v.get_x(),v.get_y());
		case EventKind.PointerScroll: EventBytes.requireSize(c.data,16); var v:PointerScrollEvent=c.data; PointerScroll(c.source,v.get_x(),v.get_y());
		case EventKind.PointerEnter: PointerEnter(c.source,c.flags!=0);
		case EventKind.Touch: EventBytes.requireSize(c.data,48); var v:TouchEvent=c.data; Touch(c.source,v.get_pointer_id(),v.get_action(),v.get_tool(),v.get_modifiers(),v.get_x(),v.get_y(),v.get_pressure(),v.get_tilt_x(),v.get_tilt_y());
		case EventKind.JoystickAxis: EventBytes.requireSize(c.data,8); var v:JoystickAxisEvent=c.data; JoystickAxis(c.source,v.get_axis(),v.get_value());
		case EventKind.JoystickButton: EventBytes.requireSize(c.data,8); var v:JoystickButtonEvent=c.data; JoystickButton(c.source,v.get_button(),v.get_pressed());
		case EventKind.JoystickHat: EventBytes.requireSize(c.data,8); var v:JoystickHatEvent=c.data; JoystickHat(c.source,v.get_hat(),v.get_value());
		case EventKind.GamepadAxis: EventBytes.requireSize(c.data,8); var v:GamepadAxisEvent=c.data; GamepadAxis(c.source,v.get_axis(),v.get_value());
		case EventKind.GamepadButton: EventBytes.requireSize(c.data,8); var v:GamepadButtonEvent=c.data; GamepadButton(c.source,v.get_button(),v.get_pressed());
		default: null;
	}
}
