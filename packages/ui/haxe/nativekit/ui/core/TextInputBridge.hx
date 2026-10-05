package nativekit.ui.core;

import nativekit.ui.widgets.text.Text;


import nativekit.ffi.NativeKitTypes.Result;
import NativeKitSurface;
import NativeKitTextInput;
import Rect;
import nativekit.ui.widgets.text.TextInputWindow;

/** Synchronizes Haxe editor state with NativeKit's custom-surface IME API. */
class TextInputBridge {
	/** Application layout to window logical coordinates for IME geometry. */
	public var coordinateScale:Float = 1.0;
	var surface:Null<NativeKitSurface>;
	var requestedActive:Bool;
	var activeOwner:Null<WidgetId>;
	var nextCaretFrameAt:Float = -1.0;
	public var platformActive(default, null):Bool;
	public var platformSupported(default, null):Bool;
	public var platformChecked(default, null):Bool;
	var disposed:Bool;
	var publishedText:Null<String>;
	final publishedState:Array<Float> = [];
	final publishedSelection:Array<Float> = [];
	final publishedComposition:Array<Float> = [];
	var publishedGeometry:Bool = false;

	public function new() {
		surface = null;
		requestedActive = false;
		activeOwner = null;
		platformActive = false;
		platformSupported = false;
		platformChecked = false;
		disposed = false;
	}

	public function attach(surface:NativeKitSurface):Void {
		ensureLive();
		if (surface == null || surface.isDisposed())
			throw "Text input requires a live NativeKit surface";
		if (this.surface == surface)
			return;
		deactivatePlatform();
		this.surface = surface;
		platformSupported = false;
		platformChecked = false;
		if (requestedActive)
			activatePlatform();
	}

	/** Activates the platform editor for one focused UI text control. */
	public function activate(?owner:WidgetId):Void {
		ensureLive();
		if (owner != null && activeOwner != null && !activeOwner.equals(owner)) {
			requestedActive = false;
			deactivatePlatform();
		}
		if (owner != null)
			activeOwner = owner;
		requestedActive = true;
		activatePlatform();
	}

	/** Deactivates the platform editor, unless another control owns it now. */
	public function deactivate(?owner:WidgetId):Void {
		ensureLive();
		if (owner != null && (activeOwner == null || !activeOwner.equals(owner)))
			return;
		requestedActive = false;
		activeOwner = null;
		deactivatePlatform();
	}

	/** Returns whether this control owns the current active text-editor session. */
	public function isOwner(owner:WidgetId):Bool
		return owner != null && activeOwner != null && activeOwner.equals(owner);

	/** Request one host frame when a focused caret next changes visibility. */
	public function requestCaretFrameAt(timeSeconds:Float):Void {
		if (requestedActive && Math.isFinite(timeSeconds) && timeSeconds >= 0.0 &&
			(nextCaretFrameAt < 0.0 || timeSeconds < nextCaretFrameAt))
			nextCaretFrameAt = timeSeconds;
	}

	/** Consume the deadline produced by the latest paint pass. */
	public function takeCaretFrameAt():Float {
		var result = nextCaretFrameAt;
		nextCaretFrameAt = -1.0;
		return result;
	}

	/** Publishes the active document, selection, composition and screen caret. */
	public function update(window:TextInputWindow, documentLength:Int, selectionStart:Int,
			selectionEnd:Int, compositionStart:Int, compositionEnd:Int,
			inputType:Int, flags:Int, cursor:Rect,
			selectionRects:Array<TextRangeRect>, compositionRects:Array<TextRangeRect>):Void {
		ensureLive();
		if (surface == null || surface.isDisposed() || !requestedActive || cursor == null ||
			(platformChecked && !platformSupported))
			return;
		if (coordinateScale != 1.0) {
			cursor = new Rect(cursor.x * coordinateScale, cursor.y * coordinateScale,
				cursor.width * coordinateScale, cursor.height * coordinateScale);
			selectionRects = scaleRects(selectionRects);
			compositionRects = scaleRects(compositionRects);
		}
		var stateChanged = publishedText != window.text || publishedState.length == 0 ||
			publishedState[0] != window.start || publishedState[1] != documentLength ||
			publishedState[2] != selectionStart || publishedState[3] != selectionEnd ||
			publishedState[4] != compositionStart || publishedState[5] != compositionEnd ||
			publishedState[6] != inputType || publishedState[7] != flags ||
			publishedState[8] != cursor.x || publishedState[9] != cursor.y ||
			publishedState[10] != cursor.width || publishedState[11] != cursor.height;
		if (stateChanged) {
			var result = NativeKitTextInput.updateResult(surface, window.text, window.start,
				documentLength, selectionStart, selectionEnd, compositionStart, compositionEnd,
				cast inputType, cast flags, null, cursor.x, cursor.y, cursor.width, cursor.height);
			if (!checkPlatformResult(result, "text-input update")) return;
			publishedText = window.text;
			publishedState[0] = window.start;
			publishedState[1] = documentLength;
			publishedState[2] = selectionStart;
			publishedState[3] = selectionEnd;
			publishedState[4] = compositionStart;
			publishedState[5] = compositionEnd;
			publishedState[6] = inputType;
			publishedState[7] = flags;
			publishedState[8] = cursor.x;
			publishedState[9] = cursor.y;
			publishedState[10] = cursor.width;
			publishedState[11] = cursor.height;
		}
		if (!stateChanged && publishedGeometry &&
			matchesRects(selectionRects, publishedSelection) &&
			matchesRects(compositionRects, publishedComposition)) return;
		var result = NativeKitTextInput.updateGeometryResult(surface, selectionStart, selectionEnd,
			compositionStart, compositionEnd, encodeRangeRects(selectionRects),
			encodeRangeRects(compositionRects));
		if (checkPlatformResult(result, "text-input geometry update")) {
			rememberRects(selectionRects, publishedSelection);
			rememberRects(compositionRects, publishedComposition);
			publishedGeometry = true;
		}
	}

	function scaleRects(rects:Array<TextRangeRect>):Array<TextRangeRect> {
		return rects == null ? [] : [for (rect in rects) new TextRangeRect(rect.start, rect.end,
			rect.x * coordinateScale, rect.y * coordinateScale,
			rect.width * coordinateScale, rect.height * coordinateScale, rect.visualLeftIsStart)];
	}

	public function dispose():Void {
		if (disposed)
			return;
		requestedActive = false;
		activeOwner = null;
		deactivatePlatform();
		surface = null;
		disposed = true;
	}

	function activatePlatform():Void {
		if (platformActive || (platformChecked && !platformSupported) || surface == null ||
			surface.isDisposed())
			return;
		if (checkPlatformResult(NativeKitTextInput.setActiveResult(surface, true),
			"text-input activation"))
			platformActive = true;
	}

	function deactivatePlatform():Void {
		publishedText = null;
		publishedState.resize(0);
		publishedGeometry = false;
		publishedSelection.resize(0);
		publishedComposition.resize(0);
		if (platformActive && platformSupported && surface != null && !surface.isDisposed())
			checkPlatformResult(NativeKitTextInput.setActiveResult(surface, false),
				"text-input deactivation");
		platformActive = false;
	}

	function checkPlatformResult(result:Result, operation:String):Bool {
		if (result == Result.ErrorUnsupported) {
			platformSupported = false;
			platformChecked = true;
			platformActive = false;
			return false;
		}
		if (result != Result.Ok)
			throw 'NativeKit $operation failed: $result';
		platformSupported = true;
		platformChecked = true;
		return true;
	}

	function ensureLive():Void {
		if (disposed)
			throw "Text input bridge has been disposed";
	}

	// Keep values rather than caller-owned rectangles, which may change in place.
	static function matchesRects(rects:Null<Array<TextRangeRect>>, values:Array<Float>):Bool {
		var count = rects == null ? 0 : rects.length;
		if (values.length != count * 7) return false;
		for (index in 0...count) {
			var rect = rects[index];
			var offset = index * 7;
			if (rect == null || values[offset] != rect.x || values[offset + 1] != rect.y ||
				values[offset + 2] != rect.width || values[offset + 3] != rect.height ||
				values[offset + 4] != rect.start || values[offset + 5] != rect.end ||
				values[offset + 6] != (rect.visualLeftIsStart ? 1 : 0)) return false;
		}
		return true;
	}

	static function rememberRects(rects:Null<Array<TextRangeRect>>, values:Array<Float>):Void {
		var count = rects == null ? 0 : rects.length;
		values.resize(count * 7);
		for (index in 0...count) {
			var rect = rects[index];
			var offset = index * 7;
			values[offset] = rect.x;
			values[offset + 1] = rect.y;
			values[offset + 2] = rect.width;
			values[offset + 3] = rect.height;
			values[offset + 4] = rect.start;
			values[offset + 5] = rect.end;
			values[offset + 6] = rect.visualLeftIsStart ? 1 : 0;
		}
	}

	static function encodeRangeRects(rects:Null<Array<TextRangeRect>>):haxe.io.Bytes {
		if (rects == null || rects.length == 0)
			return haxe.io.Bytes.alloc(0);
		if (rects.length > Std.int(0x7fffffff / 32))
			throw "Text input geometry contains too many rectangles";
		var bytes = haxe.io.Bytes.alloc(rects.length * 32);
		for (index in 0...rects.length) {
			var rect = rects[index];
			if (rect == null || rect.start < 0 || rect.end < rect.start || !finite(rect.x) ||
				!finite(rect.y) || !finite(rect.width) || !finite(rect.height) ||
				rect.width < 0.0 || rect.height < 0.0)
				throw "Text input range geometry contains an invalid rectangle";
			var offset = index * 32;
			bytes.setInt32(offset, 32);
			bytes.setFloat(offset + 4, rect.x);
			bytes.setFloat(offset + 8, rect.y);
			bytes.setFloat(offset + 12, rect.width);
			bytes.setFloat(offset + 16, rect.height);
			bytes.setInt32(offset + 20, rect.start);
			bytes.setInt32(offset + 24, rect.end);
			bytes.setInt32(offset + 28, rect.visualLeftIsStart ? 1 : 0);
		}
		return bytes;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
