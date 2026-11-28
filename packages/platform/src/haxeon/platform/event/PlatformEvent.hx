package haxeon.platform.event;

import haxeon.platform.NativeKitError;
import haxeon.platform.http.HttpResponse;
import haxeon.platform.input.TextEdit as PlatformTextEdit;
import haxeon.platform.resource.Resource;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.GamepadAxis;
import nativekit.ffi.NativeKitTypes.GamepadButton;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.InputAction;
import nativekit.ffi.NativeKitTypes.JoystickHatFlags;
import nativekit.ffi.NativeKitTypes.Key;
import nativekit.ffi.NativeKitTypes.MessageResult;
import nativekit.ffi.NativeKitTypes.Modifiers;
import nativekit.ffi.NativeKitTypes.NavigationError;
import nativekit.ffi.NativeKitTypes.PointerButton;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;
import nativekit.ffi.NativeKitTypes.TouchAction;
import nativekit.ffi.NativeKitTypes.TouchTool;
import nativekit.ffi.NativeKitTypes.WindowStateFlags;

/**
 * What happens that NativeKit reports, decoded into managed values: input, windows, surfaces, web views, audio and the
 * like. The answer to a request the app made (a clipboard read, a dialog, a task) is not one of these: it settles the
 * request's future (`Requests`), so only the caller sees it.
 */
enum PlatformEvent {
	/** Text dropped on a window. */
	DropText(source:Handle, text:String);

	/** Files dropped on a window. */
	DropFiles(source:Handle, paths:Array<String>);

	/** A web view finished loading `url`. */
	WebViewNavigated(source:Handle, url:String);

	/** A web view's page posted a message. */
	WebViewMessage(source:Handle, json:String);

	/** A web view's page changed its title. */
	WebViewTitleChanged(source:Handle, title:String);

	/** A web view failed to load a page. */
	WebViewNavigationFailed(source:Handle, category:NavigationError, message:String);

	/** A web view's page wants to load `url`; the host allows or blocks it. */
	WebViewNavigationRequest(source:Handle, request:haxe.Int64, url:String);

	/** The user activated a notification, or one of its actions. */
	NotificationActivated(request:haxe.Int64, action:String);

	/** A notification could not be shown. */
	NotificationFailed(request:haxe.Int64, message:String);

	/** An HTTP response's status and headers arrived. */
	HttpHeaders(source:Handle, request:haxe.Int64, result:NativeResult, response:HttpResponse);

	/** More of an HTTP response's body can be read. */
	HttpDataAvailable(source:Handle, request:haxe.Int64);

	/** An HTTP request's progress. */
	HttpProgressEvent(source:Handle, request:haxe.Int64, downloaded:haxe.Int64,
		downloadTotal:haxe.Int64, uploaded:haxe.Int64, uploadTotal:haxe.Int64);

	/** An HTTP request finished. */
	HttpComplete(source:Handle, request:haxe.Int64, result:NativeResult, response:HttpResponse);

	/** A native event with no typed case. */
	Raw(kind:EventKind, source:Handle, request:haxe.Int64, result:NativeResult,
		flags:Int, dataCount:Int, data:haxe.io.Bytes);

	/** The user asked to close a window. */
	WindowClose(source:Handle);

	/** A window's size changed, in logical pixels. */
	WindowResize(source:Handle, width:Int, height:Int);

	/** A window moved. */
	WindowMove(source:Handle, x:Int, y:Int);

	/** A window's framebuffer size changed, in pixels. */
	WindowFramebufferResize(source:Handle, width:Int, height:Int);

	/** A window's content scale changed. */
	WindowScaleChanged(source:Handle, scale:Float);

	/** A window was minimized, maximized, focused or the like. */
	WindowStateChanged(source:Handle, stateFlags:WindowStateFlags);

	/** A key was pressed, repeated or released. */
	Key(source:Handle, key:Key, scancode:Int, action:InputAction, modifiers:Modifiers);

	/** A character was typed. */
	TextInput(source:Handle, codepoint:Int);

	/** The input method edited the focused text. */
	TextEdit(source:Handle, edit:PlatformTextEdit);

	/** Assistive technology asked a node for an action. */
	AccessibilityAction(source:Handle, nodeId:Int, action:nativekit.ffi.NativeKitTypes.AccessibilityAction,
		value:Null<String>,
		selectionStart:Int, selectionEnd:Int, granularity:Int);

	/** The pointer moved. */
	PointerMove(source:Handle, x:Float, y:Float);

	/** A pointer button was pressed or released. */
	PointerButton(source:Handle, button:PointerButton, action:InputAction,
		modifiers:Modifiers, x:Float, y:Float);

	/** The wheel or trackpad scrolled. */
	PointerScroll(source:Handle, x:Float, y:Float);

	/** The pointer entered or left a window. */
	PointerEnter(source:Handle, entered:Bool);

	/** A touch or pen contact began, moved or ended. */
	Touch(source:Handle, pointerId:Int, action:TouchAction, tool:TouchTool,
		modifiers:Modifiers, x:Float, y:Float, pressure:Float, tiltX:Float, tiltY:Float);

	/** A joystick axis moved. */
	JoystickAxis(source:Handle, axis:Int, value:Float);

	/** A joystick button changed. */
	JoystickButton(source:Handle, button:Int, pressed:Bool);

	/** A joystick hat changed. */
	JoystickHat(source:Handle, hat:Int, value:JoystickHatFlags);

	/** A gamepad axis moved. */
	GamepadAxis(source:Handle, axis:GamepadAxis, value:Float);

	/** A gamepad button changed. */
	GamepadButton(source:Handle, button:GamepadButton, pressed:Bool);

	/** A surface can be drawn to. */
	SurfaceReady(source:Handle);

	/** A surface's size changed. */
	SurfaceResize(source:Handle, width:Int, height:Int, framebufferWidth:Int, framebufferHeight:Int);

	/** A surface's drawing context was lost. */
	SurfaceLost(source:Handle);

	/** A submitted surface frame finished. */
	SurfaceFrameComplete(source:Handle, frameToken:haxe.Int64, outcome:Result<Void, NativeKitError>);

	/** The system opened resources with the app, as when the user opens a file with it. */
	ResourcesOpened(items:Array<Resource>);

	/** Content shared to the app. */
	ShareReceived(text:Null<String>, subject:Null<String>, items:Array<Resource>);

	/** Resources dropped on a window. */
	ResourceDrop(source:Handle, x:Float, y:Float, text:Null<String>, items:Array<Resource>);

	/** A resource cache asset loaded. */
	ResourceAssetReady(source:Handle, request:haxe.Int64);

	/** A resource cache asset failed to load. */
	ResourceAssetLoadFailed(source:Handle, request:haxe.Int64, error:NativeKitError);

	/** An audio clip loaded. */
	AudioClipReady(source:Handle, request:haxe.Int64);

	/** An audio clip failed to load. */
	AudioClipLoadFailed(source:Handle, request:haxe.Int64, error:NativeKitError);

	/** An audio voice finished loading. */
	AudioVoiceReady(source:Handle);

	/** An audio voice failed to load. */
	AudioVoiceLoadFailed(source:Handle, error:NativeKitError);

	/** An audio voice reached its end. */
	AudioVoiceComplete(source:Handle);

	/** An audio voice was stopped to make room for another. */
	AudioVoiceStolen(source:Handle);

	/** An audio voice went silent to make room, keeping its place. */
	AudioVoiceVirtualized(source:Handle);

	/** A virtualized audio voice became audible again. */
	AudioVoiceResumed(source:Handle);

	/** A streaming audio voice failed to read its source. */
	AudioVoiceStreamFailed(source:Handle, error:NativeKitError);

	/** The audio device started. */
	AudioDeviceStarted;

	/** The audio device stopped. */
	AudioDeviceStopped;

	/** The audio device's output route changed. */
	AudioDeviceRerouted;

	/** Another app or a call interrupted audio. */
	AudioDeviceInterruptionBegan;

	/** The audio interruption ended. */
	AudioDeviceInterruptionEnded;

}
