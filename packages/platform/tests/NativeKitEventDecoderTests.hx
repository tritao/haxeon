import haxeon.platform.NotificationSignal;
import haxeon.platform.async.Completion;
import haxeon.platform.event.EventBytes;
import haxeon.platform.event.EventSnapshot;
import haxeon.platform.event.InputEventDecoder;
import haxeon.platform.event.NativeEvent;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.event.ResourceEventDecoder;
import haxeon.platform.event.WindowEventDecoder;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Synthetic payload tests for decoder validation and fallback behavior. */
class NativeKitEventDecoderTests {
	/** Whether `error` is what NativeKit's ErrorUnknown reports. */
	static function isUnknown(error:haxeon.platform.NativeKitError):Bool
		return switch error {
			case Failed(code, _): code == Result.ErrorUnknown.rawValue;
			case _: false;
		};

	/** What `context` decodes to when it is something that happened, else null. */
	static function happened(context:EventSnapshot):Null<PlatformEvent>
		return switch NativeEvent.decodeSnapshot(context) {
			case Happened(event): event;
			case _: null;
		};

	public static function run():Bool {
		var zeroInt = 0;
		// Request IDs are Int64; this also covers the core signed widening conversion.
		var zero:haxe.Int64 = zeroInt, empty = haxe.io.Bytes.alloc(0);
		var unknownRejected = throws(() -> {
			NativeKitTypes.NativeKitTypesEnumDecoders.decodeEventKind(0x7ffffffe);
		});
		var unknown = new EventSnapshot(EventKind.PluginEvent, handle(7), zero, Result.ErrorInvalidArgument, 3, 4,
			empty);
		var rawOk = switch happened(unknown) {
			case Raw(kind, source, _, result, flags, count, data): kind == EventKind.PluginEvent && source.rawValue
				== 7 && result == Result.ErrorInvalidArgument && flags == 3 && count == 4 && data == empty;
			case _: false;
		};
		var none = new EventSnapshot(EventKind.None, handle(0), zero, Result.Ok, 0, 0, empty);
		var nonMatch = WindowEventDecoder.decode(none) == null && InputEventDecoder.decode(none) == null
			&& ResourceEventDecoder.decode(none) == null;

		var unterminated = haxe.io.Bytes.alloc(9);
		putU32(unterminated, 0, 1);
		putU32(unterminated, 4, 8);
		unterminated.set(8, 65);
		var badResource = haxe.io.Bytes.alloc(16);
		putU32(badResource, 4, 1);
		putU32(badResource, 8, 16);
		putU32(badResource, 12, 16);
		var shortKey = new EventSnapshot(EventKind.Key, handle(0), zero, Result.Ok, 0, 0, haxe.io.Bytes.alloc(15));
		var shortWindow = new EventSnapshot(EventKind.WindowResize, handle(0), zero, Result.Ok, 0, 0,
			haxe.io.Bytes.alloc(7));
		var shortEdit = new EventSnapshot(EventKind.TextEdit, handle(0), zero, Result.Ok, 0, 0,
			haxe.io.Bytes.alloc(47));
		var messagePayload = haxe.io.Bytes.alloc(4);
		putU32(messagePayload, 0, 3);
		var messageContext = new EventSnapshot(EventKind.DialogMessageComplete, handle(0), zero, Result.Ok, 4, 0,
			messagePayload);
		var messageOk = switch NativeEvent.decodeSnapshot(messageContext) {
			case Answered(DialogMessage(_, Ok(answer))): answer.button == MessageResult.Yes && !answer.checkboxChecked;
			case _: false;
		};
		var checkedPayload = haxe.io.Bytes.alloc(8);
		putU32(checkedPayload, 0, 3);
		putU32(checkedPayload, 4, 1);
		var checkedContext = new EventSnapshot(EventKind.DialogMessageComplete, handle(0), zero, Result.Ok, 4, 0,
			checkedPayload);
		messageOk = messageOk && switch NativeEvent.decodeSnapshot(checkedContext) {
			case Answered(DialogMessage(_, Ok(answer))): answer.button == MessageResult.Yes && answer.checkboxChecked;
			case _: false;
		};
		// No button is a dialog the user dismissed.
		var dismissed = new EventSnapshot(EventKind.DialogMessageComplete, handle(0), zero, Result.Ok, 4, 0,
			haxe.io.Bytes.alloc(4));
		messageOk = messageOk && switch NativeEvent.decodeSnapshot(dismissed) {
			case Answered(DialogMessage(_, Err(Cancelled))): true;
			case _: false;
		};
		var resourcesPayload = haxe.io.Bytes.alloc(16);
		putU32(resourcesPayload, 8, 16);
		putU32(resourcesPayload, 12, 16);
		var resourcesContext = new EventSnapshot(EventKind.DialogResourcesComplete, handle(0), zero, Result.Ok, 5, 0,
			resourcesPayload);
		// A resource dialog the user did not accept answers Cancelled.
		var resourcesOk = switch NativeEvent.decodeSnapshot(resourcesContext) {
			case Answered(DialogResources(_, Err(Cancelled))): true;
			case _: false;
		};
		var resourceCacheEventsOk = switch [
			happened(new EventSnapshot(EventKind.ResourceCacheReady,
				handle(24), haxe.Int64.ofInt(25), Result.Ok, 0, 0, empty)),
			happened(new EventSnapshot(EventKind.ResourceCacheLoadFailed,
				handle(25), haxe.Int64.ofInt(26), Result.ErrorUnknown, 0, 0, empty))
		] {
			case [ResourceAssetReady(source, request), ResourceAssetLoadFailed(failedSource, failedRequest, error)]:
				source.rawValue == 24 && Std.string(request) == "25" && failedSource.rawValue == 25
					&& Std.string(failedRequest) == "26" && isUnknown(error);
			case _: false;
		};
		var editPayload = haxe.io.Bytes.alloc(50);
		putU32(editPayload, 0, TextEditAction.Compose.rawValue);
		putU32(editPayload, 4, 48);
		putU32(editPayload, 8, 2);
		putU32(editPayload, 12, 1);
		putU32(editPayload, 16, 2);
		putU32(editPayload, 20, 2);
		putU32(editPayload, 24, 2);
		putU32(editPayload, 28, 1);
		putU32(editPayload, 32, 2);
		putU32(editPayload, 36, 1);
		putU32(editPayload, 40, 6);
		editPayload.set(48, 0xc3);
		editPayload.set(49, 0xa9);
		var editContext = new EventSnapshot(EventKind.TextEdit, handle(9), zero, Result.Ok, 0, 0, editPayload);
		var editOk = switch happened(editContext) {
			case TextEdit(source, edit): source.rawValue == 9 && edit.action == TextEditAction.Compose
				&& edit.text == "é" && edit.replaceStart == 1 && edit.compositionEnd == 2 && edit.selectionAffinity == 1
				&& edit.historyKind == nativekit.ffi.NativeKitTypes.TextEditHistoryKind.Composition;
			case _: false;
		};
		var invalidEditMetadata = editPayload.sub(0, editPayload.length);
		putU32(invalidEditMetadata, 40, 7);
		var invalidEditMetadataContext = new EventSnapshot(EventKind.TextEdit,
			handle(9), zero, Result.Ok, 0, 0, invalidEditMetadata);
		var invalidUtf8 = haxe.io.Bytes.alloc(50);
		putU32(invalidUtf8, 4, 48);
		putU32(invalidUtf8, 8, 2);
		invalidUtf8.set(48, 0xc0);
		invalidUtf8.set(49, 0x80);

		var accessibilityPayload = haxe.io.Bytes.alloc(35);
		putU32(accessibilityPayload, 0, 77);
		putU32(accessibilityPayload, 4, 1);
		putU32(accessibilityPayload, 8, 32);
		putU32(accessibilityPayload, 12, 2);
		putU32(accessibilityPayload, 16, -1);
		putU32(accessibilityPayload, 20, -1);
		putU32(accessibilityPayload, 24, 1);
		accessibilityPayload.set(32, 0x6f);
		accessibilityPayload.set(33, 0x6b);
		var accessibilityContext = new EventSnapshot(EventKind.AccessibilityAction,
			handle(15), zero, Result.Ok, 0, 0, accessibilityPayload);
		var accessibilityOk = switch happened(accessibilityContext) {
			case AccessibilityAction(source, nodeId, action, value, selectionStart, selectionEnd, granularity):
				source.rawValue == 15 && nodeId == 77 && action == NativeKitTypes.AccessibilityAction.Activate
					&& value == "ok" && selectionStart == -1
					&& selectionEnd == -1 && granularity == 1;
			case _: false;
		};
		// An action code newer than the binding keeps the event, as a Raw one.
		var newerAccessibilityPayload = accessibilityPayload.sub(0, accessibilityPayload.length);
		putU32(newerAccessibilityPayload, 4, 999);
		var newerAccessibilityOk = switch happened(new EventSnapshot(EventKind.AccessibilityAction,
			handle(15), zero, Result.Ok, 0, 0, newerAccessibilityPayload)) {
				case Raw(kind, _, _, _, _, _, _): kind == EventKind.AccessibilityAction;
				case _: false;
			};
		var unterminatedAccessibility = accessibilityPayload.sub(0, 34);
		var unterminatedAccessibilityContext = new EventSnapshot(EventKind.AccessibilityAction,
			handle(15), zero, Result.Ok, 0, 0, unterminatedAccessibility);

		var keyPayload = haxe.io.Bytes.alloc(16);
		putU32(keyPayload, 0, Key.Escape.rawValue);
		putU32(keyPayload, 4, 41);
		putU32(keyPayload, 8, InputAction.Press.rawValue);
		putU32(keyPayload, 12, Modifiers.Control.rawValue | (1 << 30));
		var keyContext = new EventSnapshot(EventKind.Key, handle(12), zero, Result.Ok, 0, 0, keyPayload);
		var typedKeyOk = switch happened(keyContext) {
			case Key(source, key, scancode, action, modifiers):
				source.rawValue == 12 && key == Key.Escape && scancode == 41 && action == InputAction.Press
					&& modifiers == Modifiers.Control;
			case _: false;
		};
		// GTK can report the unnamed sixth/seventh buttons; the binding import
		// header completes that finite native domain without accepting arbitrary codes.
		var extraButtonsOk = true;
		for (code in [5, 6]) {
			var payload = haxe.io.Bytes.alloc(32);
			putU32(payload, 0, code);
			putU32(payload, 4, InputAction.Press.rawValue);
			var snapshot = new EventSnapshot(EventKind.PointerButton, handle(12), zero, Result.Ok, 0, 0, payload);
			extraButtonsOk = extraButtonsOk && switch happened(snapshot) {
				case PointerButton(_, button, action, _, _, _): button.rawValue == code
					&& action == InputAction.Press;
				case _: false;
			};
		}
		var invalidButtonRejected = throws(() -> {
			NativeKitTypes.NativeKitTypesEnumDecoders.decodePointerButton(8);
		});
		var hatPayload = haxe.io.Bytes.alloc(8);
		putU32(hatPayload, 0, 2);
		putU32(hatPayload, 4, (JoystickHatFlags.Up | JoystickHatFlags.Left).rawValue);
		var hatContext = new EventSnapshot(EventKind.JoystickHat, handle(13), zero, Result.Ok, 0, 0, hatPayload);
		var typedHatOk = switch happened(hatContext) {
			case JoystickHat(source, hat, value):
				source.rawValue == 13 && hat == 2 && value.contains(JoystickHatFlags.Up)
					&& value.contains(JoystickHatFlags.Left);
			case _: false;
		};
		var navigationContext = new EventSnapshot(EventKind.WebviewNavigationFailed, handle(14), zero, Result.Ok,
			NavigationError.NotFound.rawValue, 0, empty);
		var typedNavigationOk = switch happened(navigationContext) {
			case WebViewNavigationFailed(source, category, _): source.rawValue == 14
				&& category == NavigationError.NotFound;
			case _: false;
		};
		var taskPayload = haxe.io.Bytes.alloc(4);
		putU32(taskPayload, 0, 0x1234);
		var taskContext = new EventSnapshot(EventKind.TaskComplete, handle(21), zero, Result.Ok,
			0, 1, taskPayload);
		// A notification's events go to it alone, by request id: an activation with its action, a failure with its message.
		var noted = haxe.Int64.ofInt(31);
		var notificationsOk = switch [
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.NotificationDelivered, handle(0), noted, Result.Ok,
				0, 0,
				empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.NotificationActivated, handle(0), noted, Result.Ok,
				0, 0,
				haxe.io.Bytes.ofString("reply"))),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.NotificationDismissed, handle(0), noted, Result.Ok,
				0, 0,
				empty)),
			NativeEvent.decodeSnapshot(new EventSnapshot(EventKind.NotificationFailed, handle(0), noted,
				Result.ErrorUnknown,
				0, 0, haxe.io.Bytes.ofString("no server")))
		] {
			case [
				Notified(Delivered(_)),
				Notified(Activated(_, "reply")),
				Notified(Dismissed(_)),
				Notified(Failed(_, Failed(_, "no server")))
			]: true;
			case _: false;
		};
		var taskOk = switch NativeEvent.decodeSnapshot(taskContext) {
			case Answered(TaskComplete(source, data)): source.rawValue == 21 && data == taskPayload;
			case _: false;
		};
		var audioContext = new EventSnapshot(EventKind.AudioVoiceComplete,
			handle(16), zero, Result.Ok, 0, 0, empty);
		var audioOk = switch happened(audioContext) {
			case AudioVoiceComplete(source): source.rawValue == 16;
			case _: false;
		};
		var audioTransitionEventsOk = switch [
			happened(new EventSnapshot(EventKind.AudioVoiceStolen,
				handle(21), zero, Result.Ok, 0, 0, empty)),
			happened(new EventSnapshot(EventKind.AudioVoiceVirtualized,
				handle(22), zero, Result.Ok, 0, 0, empty)),
			happened(new EventSnapshot(EventKind.AudioVoiceResumed,
				handle(23), zero, Result.Ok, 0, 0, empty))
		] {
			case [AudioVoiceStolen(stolen), AudioVoiceVirtualized(virtualized), AudioVoiceResumed(resumed)]:
				stolen.rawValue == 21 && virtualized.rawValue == 22 && resumed.rawValue == 23;
			case _: false;
		};
		var audioReadyContext = new EventSnapshot(EventKind.AudioVoiceReady,
			handle(17), zero, Result.Ok, 0, 0, empty);
		var audioReadyOk = switch happened(audioReadyContext) {
			case AudioVoiceReady(source): source.rawValue == 17;
			case _: false;
		};
		var audioFailedContext = new EventSnapshot(EventKind.AudioVoiceLoadFailed,
			handle(18), zero, Result.ErrorUnknown, 0, 0, empty);
		var audioFailedOk = switch happened(audioFailedContext) {
			case AudioVoiceLoadFailed(source, error):
				source.rawValue == 18 && isUnknown(error);
			case _: false;
		};
		var audioClipReadyContext = new EventSnapshot(EventKind.AudioClipReady,
			handle(19), haxe.Int64.ofInt(19), Result.Ok, 0, 0, empty);
		var audioClipReadyOk = switch happened(audioClipReadyContext) {
			case AudioClipReady(source, request):
				source.rawValue == 19 && Std.string(request) == "19";
			case _: false;
		};
		var audioClipFailedContext = new EventSnapshot(EventKind.AudioClipLoadFailed,
			handle(20), haxe.Int64.ofInt(20), Result.ErrorUnknown, 0, 0, empty);
		var audioClipFailedOk = switch happened(audioClipFailedContext) {
			case AudioClipLoadFailed(source, request, error):
				source.rawValue == 20 && Std.string(request) == "20" && isUnknown(error);
			case _: false;
		};
		var audioStreamFailedContext = new EventSnapshot(EventKind.AudioVoiceStreamFailed,
			handle(24), zero, Result.ErrorUnknown, 0, 0, empty);
		var audioStreamFailedOk = switch happened(audioStreamFailedContext) {
			case AudioVoiceStreamFailed(source, error):
				source.rawValue == 24 && isUnknown(error);
			case _: false;
		};
		var audioDeviceEventsOk = switch [
			happened(new EventSnapshot(EventKind.AudioDeviceStarted, handle(0), zero, Result.Ok, 0, 0,
				empty)),
			happened(new EventSnapshot(EventKind.AudioDeviceStopped, handle(0), zero, Result.Ok, 0, 0,
				empty)),
			happened(new EventSnapshot(EventKind.AudioDeviceRerouted, handle(0), zero, Result.Ok, 0,
				0, empty)),
			happened(new EventSnapshot(EventKind.AudioDeviceInterruptionBegan, handle(0), zero,
				Result.Ok, 0, 0, empty)),
			happened(new EventSnapshot(EventKind.AudioDeviceInterruptionEnded, handle(0), zero,
				Result.Ok, 0, 0, empty))
		] {
			case [
				AudioDeviceStarted,
				AudioDeviceStopped,
				AudioDeviceRerouted,
				AudioDeviceInterruptionBegan,
				AudioDeviceInterruptionEnded
			]: true;
			case _: false;
		};

		if (!messageOk) throw "message completion decoding failed";
		if (!resourcesOk) throw "resource completion decoding failed";
		if (!resourceCacheEventsOk) throw "resource cache event decoding failed";
		return decodedResourceIsReusable() && unknownRejected && rawOk && nonMatch && editOk && extraButtonsOk
			&& invalidButtonRejected && typedKeyOk && typedHatOk && typedNavigationOk && accessibilityOk
			&& newerAccessibilityOk && taskOk && notificationsOk
			&& audioOk
			&& audioReadyOk && audioFailedOk
			&& audioClipReadyOk && audioClipFailedOk
			&& audioTransitionEventsOk
			&& audioStreamFailedOk
			&& audioDeviceEventsOk
			&& throws(() -> {
				EventBytes.requireSize(haxe.io.Bytes.alloc(3), 4);
			})
				&& throws(() -> {
			EventBytes.readU32(haxe.io.Bytes.alloc(3), 0);
		})
			&& throws(() -> {
			EventBytes.decodeClipboardFiles(unterminated, 1);
		})
			&& throws(() -> {
			EventBytes.decodeResourceList(badResource, 0);
		})
			&& throws(() -> {
			InputEventDecoder.decode(shortKey);
		})
			&& throws(() -> {
			InputEventDecoder.decode(shortEdit);
		})
			&& throws(() -> {
			InputEventDecoder.decode(invalidEditMetadataContext);
		})
			&& throws(() -> {
			InputEventDecoder.decode(unterminatedAccessibilityContext);
		})
			&& throws(() -> {
			WindowEventDecoder.decode(shortWindow);
		})
			&& throws(() -> {
			EventBytes.readUtf8Slice(invalidUtf8, 48, 2, 48);
		});
	}

	/** A decoded event resource must be the same managed value accepted by resource APIs. */
	static function decodedResourceIsReusable():Bool {
		var uri = haxe.io.Bytes.ofString("file:///tmp/item");
		var mime = haxe.io.Bytes.ofString("text/plain");
		var name = haxe.io.Bytes.ofString("Item");
		var uriOffset = 32, mimeOffset = uriOffset + uri.length + 1, nameOffset = mimeOffset + mime.length + 1;
		var payload = haxe.io.Bytes.alloc(nameOffset + name.length + 1);
		putU32(payload, 0, 1);
		putU32(payload, 4, 1);
		putU32(payload, 8, 16);
		putU32(payload, 12, 32);
		putU32(payload, 16, (ResourceFlags.Readable | ResourceFlags.Persisted).rawValue);
		putU32(payload, 20, uriOffset);
		putU32(payload, 24, mimeOffset);
		putU32(payload, 28, nameOffset);
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
