package haxeon.ui.gestures;

/** Gesture recognizer output categories. */
class GestureKind {
	public static inline var Tap:Int = 1;
	public static inline var DoubleTap:Int = 2;
	public static inline var LongPress:Int = 3;
	public static inline var DragStart:Int = 4;
	public static inline var Drag:Int = 5;
	public static inline var DragEnd:Int = 6;
	/** Recognizer category for two-pointer pinch; its events are PinchStart, PinchUpdate and PinchEnd. */
	public static inline var Pinch:Int = 7;
	public static inline var PinchStart:Int = 8;
	public static inline var PinchUpdate:Int = 9;
	public static inline var PinchEnd:Int = 10;
	/** Recognizer category and event for a fast horizontal flick. */
	public static inline var Swipe:Int = 11;
}
