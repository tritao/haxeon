package haxeon.platform.event;

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
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.TouchAction;
import nativekit.ffi.NativeKitTypes.TouchTool;
import nativekit.ffi.NativeKitTypes.WindowStateFlags;

enum PlatformEvent {
	None;
	ClipboardText(request:haxe.Int64, result:Result, text:String);
	ClipboardFiles(request:haxe.Int64, result:Result, paths:Array<String>);
	DropText(source:Handle, text:String);
	DropFiles(source:Handle, paths:Array<String>);
	DialogMessage(request:haxe.Int64, result:Result, button:MessageResult);
	WebViewNavigated(source:Handle, url:String);
	WebViewMessage(source:Handle, json:String);
	WebViewTitleChanged(source:Handle, title:String);
	WebViewEvaluation(source:Handle, request:haxe.Int64, result:Result, json:String);
	WebViewNavigationFailed(source:Handle, category:NavigationError, message:String);
	WebViewNavigationRequest(source:Handle, request:haxe.Int64, url:String);
	NotificationActivated(request:haxe.Int64, action:String);
	NotificationFailed(request:haxe.Int64, message:String);
	TaskProgress(source:Handle, data:haxe.io.Bytes);
	TaskComplete(source:Handle, result:Result, data:haxe.io.Bytes);
	TaskFailed(source:Handle, result:Result, data:haxe.io.Bytes);
	TaskCancelled(source:Handle, result:Result, data:haxe.io.Bytes);
	HttpHeaders(source:Handle, request:haxe.Int64, result:Result, response:HttpResponse);
	HttpDataAvailable(source:Handle, request:haxe.Int64);
	HttpProgressEvent(source:Handle, request:haxe.Int64, downloaded:haxe.Int64,
		downloadTotal:haxe.Int64, uploaded:haxe.Int64, uploadTotal:haxe.Int64);
	HttpComplete(source:Handle, request:haxe.Int64, result:Result, response:HttpResponse);
	Raw(kind:EventKind, source:Handle, request:haxe.Int64, result:Result,
		flags:Int, dataCount:Int, data:haxe.io.Bytes);
	WindowClose(source:Handle);
	WindowResize(source:Handle, width:Int, height:Int);
	WindowMove(source:Handle, x:Int, y:Int);
	WindowFramebufferResize(source:Handle, width:Int, height:Int);
	WindowScaleChanged(source:Handle, scale:Float);
	WindowStateChanged(source:Handle, stateFlags:WindowStateFlags);
	Key(source:Handle, key:Key, scancode:Int, action:InputAction, modifiers:Modifiers);
	TextInput(source:Handle, codepoint:Int);
	TextEdit(source:Handle, edit:PlatformTextEdit);
	AccessibilityAction(source:Handle, nodeId:Int, action:Int, value:Null<String>,
		selectionStart:Int, selectionEnd:Int, granularity:Int);
	PointerMove(source:Handle, x:Float, y:Float);
	PointerButton(source:Handle, button:PointerButton, action:InputAction,
		modifiers:Modifiers, x:Float, y:Float);
	PointerScroll(source:Handle, x:Float, y:Float);
	PointerEnter(source:Handle, entered:Bool);
	Touch(source:Handle, pointerId:Int, action:TouchAction, tool:TouchTool,
		modifiers:Modifiers, x:Float, y:Float, pressure:Float, tiltX:Float, tiltY:Float);
	JoystickAxis(source:Handle, axis:Int, value:Float);
	JoystickButton(source:Handle, button:Int, pressed:Bool);
	JoystickHat(source:Handle, hat:Int, value:JoystickHatFlags);
	GamepadAxis(source:Handle, axis:GamepadAxis, value:Float);
	GamepadButton(source:Handle, button:GamepadButton, pressed:Bool);
	SurfaceReady(source:Handle);
	SurfaceResize(source:Handle, width:Int, height:Int, framebufferWidth:Int, framebufferHeight:Int);
	SurfaceLost(source:Handle);
	Resources(kind:EventKind, request:haxe.Int64, result:Result, accepted:Bool, items:Array<Resource>);
	ShareReceived(text:Null<String>, subject:Null<String>, items:Array<Resource>);
	ResourceDrop(source:Handle, x:Float, y:Float, text:Null<String>, items:Array<Resource>);
	ResourceCommit(request:haxe.Int64, result:Result, downloadInitiated:Bool);
	ResourceAssetReady(source:Handle, request:haxe.Int64);
	ResourceAssetLoadFailed(source:Handle, request:haxe.Int64, result:Result);
	AudioClipReady(source:Handle, request:haxe.Int64);
	AudioClipLoadFailed(source:Handle, request:haxe.Int64, result:Result);
	AudioVoiceReady(source:Handle);
	AudioVoiceLoadFailed(source:Handle, result:Result);
	AudioVoiceComplete(source:Handle);
	AudioVoiceStolen(source:Handle);
	AudioVoiceVirtualized(source:Handle);
	AudioVoiceResumed(source:Handle);
	AudioVoiceStreamFailed(source:Handle, result:Result);
	AudioDeviceStarted;
	AudioDeviceStopped;
	AudioDeviceRerouted;
	AudioDeviceInterruptionBegan;
	AudioDeviceInterruptionEnded;

}
