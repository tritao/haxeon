import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.EventSnapshot;
import haxeon.platform.internal.event.InputEventDecoder;
import haxeon.platform.internal.event.NativeEvent;
import haxeon.platform.internal.event.ResourceEventDecoder;
import haxeon.platform.internal.event.WindowEventDecoder;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Synthetic payload tests for decoder validation and fallback behavior. */
class NativeKitEventDecoderTests {
	public static function run():Bool {
		var zeroInt = 0;
		// Request IDs are Int64; this also covers the core signed widening conversion.
		var zero:haxe.Int64 = zeroInt, empty = haxe.io.Bytes.alloc(0);
		var unknown = new EventSnapshot(0x7ffffffe, handle(7), zero, -2, 3, 4, empty);
		var rawOk = switch NativeEvent.decodeSnapshot(unknown) {
			case Raw(kind, source, _, result, flags, count, data): kind == 0x7ffffffe && source.rawValue() == 7 && result == -2 && flags == 3 && count == 4 && data == empty;
			case _: false;
		};
		var none = new EventSnapshot(EventKind.None, handle(0), zero, 0, 0, 0, empty);
		var nonMatch = WindowEventDecoder.decode(none) == null && InputEventDecoder.decode(none) == null && ResourceEventDecoder.decode(none) == null;

		var unterminated = haxe.io.Bytes.alloc(9);
		putU32(unterminated, 0, 1); putU32(unterminated, 4, 8); unterminated.set(8, 65);
		var badResource = haxe.io.Bytes.alloc(16);
		putU32(badResource, 4, 1); putU32(badResource, 8, 16); putU32(badResource, 12, 16);
		var shortKey = new EventSnapshot(EventKind.Key, handle(0), zero, 0, 0, 0, haxe.io.Bytes.alloc(15));
		var shortWindow = new EventSnapshot(EventKind.WindowResize, handle(0), zero, 0, 0, 0, haxe.io.Bytes.alloc(7));
		var shortEdit = new EventSnapshot(EventKind.TextEdit, handle(0), zero, 0, 0, 0, haxe.io.Bytes.alloc(47));
		var messagePayload = haxe.io.Bytes.alloc(4);
		putU32(messagePayload, 0, 3);
		var messageContext = new EventSnapshot(EventKind.DialogMessageComplete, handle(0), zero, 0, 4, 0, messagePayload);
		var messageOk = switch NativeEvent.decodeSnapshot(messageContext) {
			case DialogMessage(_, 0, 3, false): true;
			case _: false;
		};
		var checkedPayload = haxe.io.Bytes.alloc(8);
		putU32(checkedPayload, 0, 3); putU32(checkedPayload, 4, 1);
		var checkedContext = new EventSnapshot(EventKind.DialogMessageComplete, handle(0), zero, 0, 4, 0, checkedPayload);
		messageOk = messageOk && switch NativeEvent.decodeSnapshot(checkedContext) {
			case DialogMessage(_, 0, 3, true): true;
			case _: false;
		};
		var resourcesPayload = haxe.io.Bytes.alloc(16);
		putU32(resourcesPayload, 8, 16); putU32(resourcesPayload, 12, 16);
		var resourcesContext = new EventSnapshot(EventKind.DialogResourcesComplete, handle(0), zero, 0, 5, 0, resourcesPayload);
		var resourcesOk = switch NativeEvent.decodeSnapshot(resourcesContext) {
			case Resources(kind, _, result, accepted, items): kind == EventKind.DialogResourcesComplete && result == 0 && !accepted && items.length == 0;
			case _: false;
		};
		var resourceCacheEventsOk = switch [
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.ResourceCacheReady,
				handle(24), haxe.Int64.ofInt(25), 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.ResourceCacheLoadFailed,
				handle(25), haxe.Int64.ofInt(26), Result.ErrorUnknown, 0, 0, empty))
		] {
			case [ResourceAssetReady(source, request), ResourceAssetLoadFailed(failedSource, failedRequest, result)]:
				source.rawValue() == 24 && Std.string(request) == "25" && failedSource.rawValue() == 25 &&
				Std.string(failedRequest) == "26" && result == Result.ErrorUnknown;
			case _: false;
		};
		var editPayload = haxe.io.Bytes.alloc(50);
		putU32(editPayload, 0, TextEditAction.Compose);
		putU32(editPayload, 4, 48); putU32(editPayload, 8, 2);
		putU32(editPayload, 12, 1); putU32(editPayload, 16, 2);
		putU32(editPayload, 20, 2); putU32(editPayload, 24, 2);
		putU32(editPayload, 28, 1); putU32(editPayload, 32, 2);
		putU32(editPayload, 36, 1); putU32(editPayload, 40, 6);
		editPayload.set(48, 0xc3); editPayload.set(49, 0xa9);
		var editContext = new EventSnapshot(EventKind.TextEdit, handle(9), zero, 0, 0, 0, editPayload);
		var editOk = switch NativeEvent.decodeSnapshot(editContext) {
			case TextEdit(source, edit): source.rawValue() == 9 && edit.action == TextEditAction.Compose && edit.text == "é" && edit.replaceStart == 1 && edit.compositionEnd == 2 && edit.selectionAffinity == 1 && edit.historyKind == 6;
			case _: false;
		};
		var invalidEditMetadata = editPayload.sub(0, editPayload.length);
		putU32(invalidEditMetadata, 40, 7);
		var invalidEditMetadataContext = new EventSnapshot(EventKind.TextEdit,
			handle(9), zero, 0, 0, 0, invalidEditMetadata);
		var invalidUtf8 = haxe.io.Bytes.alloc(50);
		putU32(invalidUtf8, 4, 48); putU32(invalidUtf8, 8, 2);
		invalidUtf8.set(48, 0xc0); invalidUtf8.set(49, 0x80);

		var accessibilityPayload = haxe.io.Bytes.alloc(35);
		putU32(accessibilityPayload, 0, 77); putU32(accessibilityPayload, 4, 1);
		putU32(accessibilityPayload, 8, 32); putU32(accessibilityPayload, 12, 2);
		putU32(accessibilityPayload, 16, -1); putU32(accessibilityPayload, 20, -1);
		putU32(accessibilityPayload, 24, 1);
		accessibilityPayload.set(32, 0x6f); accessibilityPayload.set(33, 0x6b);
		var accessibilityContext = new EventSnapshot(EventKind.AccessibilityAction,
			handle(15), zero, 0, 0, 0, accessibilityPayload);
		var accessibilityOk = switch NativeEvent.decodeSnapshot(accessibilityContext) {
			case AccessibilityAction(source, nodeId, action, value, selectionStart, selectionEnd, granularity):
				source.rawValue() == 15 && nodeId == 77 && action == 1 && value == "ok" &&
				selectionStart == -1 && selectionEnd == -1 && granularity == 1;
			case _: false;
		};
		var unterminatedAccessibility = accessibilityPayload.sub(0, 34);
		var unterminatedAccessibilityContext = new EventSnapshot(EventKind.AccessibilityAction,
			handle(15), zero, 0, 0, 0, unterminatedAccessibility);

		var keyPayload = haxe.io.Bytes.alloc(16);
		putU32(keyPayload, 0, Key.Escape); putU32(keyPayload, 4, 41);
		putU32(keyPayload, 8, InputAction.Press); putU32(keyPayload, 12, Modifiers.Control);
		var keyContext = new EventSnapshot(EventKind.Key, handle(12), zero, 0, 0, 0, keyPayload);
		var typedKeyOk = switch NativeEvent.decodeSnapshot(keyContext) {
			case Key(source, key, scancode, action, modifiers):
				source.rawValue() == 12 && key == Key.Escape && scancode == 41 && action == InputAction.Press
					&& (modifiers & Modifiers.Control) != 0;
			case _: false;
		};
		var hatPayload = haxe.io.Bytes.alloc(8);
		putU32(hatPayload, 0, 2); putU32(hatPayload, 4, JoystickHatFlags.Up | JoystickHatFlags.Left);
		var hatContext = new EventSnapshot(EventKind.JoystickHat, handle(13), zero, 0, 0, 0, hatPayload);
		var typedHatOk = switch NativeEvent.decodeSnapshot(hatContext) {
			case JoystickHat(source, hat, value):
				source.rawValue() == 13 && hat == 2 && (value & JoystickHatFlags.Up) != 0
					&& (value & JoystickHatFlags.Left) != 0;
			case _: false;
		};
		var navigationContext = new EventSnapshot(EventKind.WebviewNavigationFailed, handle(14), zero, 0,
			NavigationError.NotFound, 0, empty);
		var typedNavigationOk = switch NativeEvent.decodeSnapshot(navigationContext) {
			case WebViewNavigationFailed(source, category, _): source.rawValue() == 14 && category == NavigationError.NotFound;
			case _: false;
		};
		var taskPayload = haxe.io.Bytes.alloc(4);
		putU32(taskPayload, 0, 0x1234);
		var taskContext = new EventSnapshot(EventKind.TaskComplete, handle(21), zero, 0,
			0, 1, taskPayload);
		var taskOk = switch NativeEvent.decodeSnapshot(taskContext) {
			case TaskComplete(source, result, data): source.rawValue() == 21 && result == 0 && data == taskPayload;
			case _: false;
		};
		var audioContext = new EventSnapshot(EventKind.AudioVoiceComplete,
			handle(16), zero, 0, 0, 0, empty);
		var audioOk = switch NativeEvent.decodeSnapshot(audioContext) {
			case AudioVoiceComplete(source): source.rawValue() == 16;
			case _: false;
		};
		var audioTransitionEventsOk = switch [
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioVoiceStolen,
				handle(21), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioVoiceVirtualized,
				handle(22), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioVoiceResumed,
				handle(23), zero, 0, 0, 0, empty))
		] {
			case [AudioVoiceStolen(stolen), AudioVoiceVirtualized(virtualized), AudioVoiceResumed(resumed)]:
				stolen.rawValue() == 21 && virtualized.rawValue() == 22 && resumed.rawValue() == 23;
			case _: false;
		};
		var audioReadyContext = new EventSnapshot(EventKind.AudioVoiceReady,
			handle(17), zero, 0, 0, 0, empty);
		var audioReadyOk = switch NativeEvent.decodeSnapshot(audioReadyContext) {
			case AudioVoiceReady(source): source.rawValue() == 17;
			case _: false;
		};
		var audioFailedContext = new EventSnapshot(EventKind.AudioVoiceLoadFailed,
			handle(18), zero, Result.ErrorUnknown, 0, 0, empty);
		var audioFailedOk = switch NativeEvent.decodeSnapshot(audioFailedContext) {
			case AudioVoiceLoadFailed(source, result):
				source.rawValue() == 18 && result == Result.ErrorUnknown;
			case _: false;
		};
		var audioClipReadyContext = new EventSnapshot(EventKind.AudioClipReady,
			handle(19), haxe.Int64.ofInt(19), Result.Ok, 0, 0, empty);
		var audioClipReadyOk = switch NativeEvent.decodeSnapshot(audioClipReadyContext) {
			case AudioClipReady(source, request):
				source.rawValue() == 19 && Std.string(request) == "19";
			case _: false;
		};
		var audioClipFailedContext = new EventSnapshot(EventKind.AudioClipLoadFailed,
			handle(20), haxe.Int64.ofInt(20), Result.ErrorUnknown, 0, 0, empty);
		var audioClipFailedOk = switch NativeEvent.decodeSnapshot(audioClipFailedContext) {
			case AudioClipLoadFailed(source, request, result):
				source.rawValue() == 20 && Std.string(request) == "20" && result == Result.ErrorUnknown;
			case _: false;
		};
		var audioStreamFailedContext = new EventSnapshot(EventKind.AudioVoiceStreamFailed,
			handle(24), zero, Result.ErrorUnknown, 0, 0, empty);
		var audioStreamFailedOk = switch NativeEvent.decodeSnapshot(audioStreamFailedContext) {
			case AudioVoiceStreamFailed(source, result):
				source.rawValue() == 24 && result == Result.ErrorUnknown;
			case _: false;
		};
		var audioDeviceEventsOk = switch [
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioDeviceStarted, handle(0), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioDeviceStopped, handle(0), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioDeviceRerouted, handle(0), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioDeviceInterruptionBegan, handle(0), zero, 0, 0, 0, empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.AudioDeviceInterruptionEnded, handle(0), zero, 0, 0, 0, empty))
		] {
			case [AudioDeviceStarted, AudioDeviceStopped, AudioDeviceRerouted,
				AudioDeviceInterruptionBegan, AudioDeviceInterruptionEnded]: true;
			case _: false;
		};

		if (!messageOk) throw "message completion decoding failed";
		if (!resourcesOk) throw "resource completion decoding failed";
		if (!resourceCacheEventsOk) throw "resource cache event decoding failed";
		return decodedResourceIsReusable() && rawOk && nonMatch && editOk && typedKeyOk && typedHatOk && typedNavigationOk && accessibilityOk && taskOk && audioOk
			&& audioReadyOk && audioFailedOk
			&& audioClipReadyOk && audioClipFailedOk
			&& audioTransitionEventsOk
			&& audioStreamFailedOk
			&& audioDeviceEventsOk
			&& throws(function() { EventBytes.requireSize(haxe.io.Bytes.alloc(3), 4); })
			&& throws(function() { EventBytes.readU32(haxe.io.Bytes.alloc(3), 0); })
			&& throws(function() { EventBytes.decodeClipboardFiles(unterminated, 1); })
			&& throws(function() { EventBytes.decodeResourceList(badResource, 0); })
			&& throws(function() { InputEventDecoder.decode(shortKey); })
			&& throws(function() { InputEventDecoder.decode(shortEdit); })
			&& throws(function() { InputEventDecoder.decode(invalidEditMetadataContext); })
			&& throws(function() { InputEventDecoder.decode(unterminatedAccessibilityContext); })
			&& throws(function() { WindowEventDecoder.decode(shortWindow); })
			&& throws(function() { EventBytes.readUtf8Slice(invalidUtf8,48,2,48); });
	}

	/** A decoded event resource must be the same managed value accepted by resource APIs. */
	static function decodedResourceIsReusable():Bool {
		var uri = haxe.io.Bytes.ofString("file:///tmp/item");
		var mime = haxe.io.Bytes.ofString("text/plain");
		var name = haxe.io.Bytes.ofString("Item");
		var uriOffset = 32, mimeOffset = uriOffset + uri.length + 1, nameOffset = mimeOffset + mime.length + 1;
		var payload = haxe.io.Bytes.alloc(nameOffset + name.length + 1);
		putU32(payload, 0, 1); putU32(payload, 4, 1); putU32(payload, 8, 16); putU32(payload, 12, 32);
		putU32(payload, 16, ResourceFlags.Readable | ResourceFlags.Persisted);
		putU32(payload, 20, uriOffset); putU32(payload, 24, mimeOffset); putU32(payload, 28, nameOffset);
		payload.blit(uriOffset, uri, 0, uri.length);
		payload.blit(mimeOffset, mime, 0, mime.length);
		payload.blit(nameOffset, name, 0, name.length);
		var decoded = EventBytes.decodeResourceList(payload, 0);
		if (!decoded.accepted || decoded.items.length != 1) return false;
		var resource:haxeon.platform.resource.Resource = decoded.items[0];
		var nativeValue = resource.nativeValue();
		return resource.uri == "file:///tmp/item" && resource.mimeType == "text/plain" && resource.displayName == "Item"
			&& resource.flags == (ResourceFlags.Readable | ResourceFlags.Persisted)
			&& nativeValue.get_uri() == resource.uri && nativeValue.get_mime_type() == resource.mimeType
			&& nativeValue.get_display_name() == resource.displayName && nativeValue.get_flags() == resource.flags;
	}

	static function putU32(data:haxe.io.Bytes, offset:Int, value:Int):Void {
		for (index in 0...4) data.set(offset + index, value >>> (index * 8) & 0xff);
	}

	static inline function handle(value:Int):Handle
		return new Handle(value);

	static function throws(action:Void->Void):Bool {
		try action() catch (_:Dynamic) return true;
		return false;
	}
}
