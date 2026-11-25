package haxeon.ui.style;

/** Runtime capabilities/preferences available to conditional style rules. */
class StyleEnvironment {
	static var nextIdentity:Int = 0;

	/** Stable identity prevents separate environments at revision zero colliding. */
	public final identity:Int;

	/** The viewport's width, in logical pixels. */
	public var width:Float;

	/** The viewport's height, in logical pixels. */
	public var height:Float;
	var pixelDensityValue:Float;

	/** Device pixels per logical pixel. */
	public var pixelDensity(get, set):Float;

	/** An `EnvironmentOrientation` value. */
	public var orientation:Int;
	var platformValue:String;

	/** The platform's name, such as "macos" or "web". */
	public var platform(get, set):String;
	var colorSchemeValue:Int;

	/** An `EnvironmentColorScheme` value: what the user asked the system for. */
	public var colorScheme(get, set):Int;
	var pointerValue:Int;

	/** An `EnvironmentPointer` value: how precise the main pointer is. */
	public var pointer(get, set):Int;
	var hoverSupportedValue:Bool;

	/** Whether the pointer can hover. */
	public var hoverSupported(get, set):Bool;
	var textScaleValue:Float;

	/** The user's text size multiplier. */
	public var textScale(get, set):Float;
	var reducedMotionValue:Bool;

	/** Whether the user asked for less motion. */
	public var reducedMotion(get, set):Bool;
	var scrollbarVisibilityValue:Int = haxeon.ui.widgets.scroll.ScrollView.ScrollbarVisibility.Auto;

	/** A `ScrollbarVisibility` value: the system's scrollbar preference. */
	public var scrollbarVisibility(get, set):Int;
	var highContrastValue:Bool;

	/** Whether the user asked for high contrast. */
	public var highContrast(get, set):Bool;

	/** Counts the changes, so styles depending on the environment are resolved again. */
	public var revision(default, null):Int;

	/** An environment with a viewport of `width` by `height`. */
	public function new(width:Float = 0.0, height:Float = 0.0) {
		identity = nextIdentity++;
		this.width = width;
		this.height = height;
		pixelDensityValue = 1.0;
		orientation = EnvironmentOrientation.Unknown;
		platformValue = "unknown";
		colorSchemeValue = EnvironmentColorScheme.Light;
		pointerValue = EnvironmentPointer.Fine;
		hoverSupportedValue = true;
		textScaleValue = 1.0;
		reducedMotionValue = false;
		highContrastValue = false;
		revision = 0;
		refreshOrientation();
	}

	/** Sets the viewport's size, counting a change only when it differs. Throws when a side is not positive. */
	public function setViewport(width:Float, height:Float):Void {
		if (width <= 0.0 || height <= 0.0)
			throw "Style environment viewport must be positive";
		if (this.width == width && this.height == height)
			return;
		this.width = width;
		this.height = height;
		refreshOrientation();
		revision++;
	}

	function get_pixelDensity():Float return pixelDensityValue;
	function set_pixelDensity(value:Float):Float {
		if (value <= 0.0)
			throw "Style environment pixel density must be positive";
		if (pixelDensityValue != value) {
			pixelDensityValue = value;
			revision++;
		}
		return value;
	}

	function get_platform():String return platformValue;
	function set_platform(value:String):String {
		if (value == null || value.length == 0)
			throw "Style environment platform must be non-empty";
		if (platformValue != value) {
			platformValue = value;
			revision++;
		}
		return value;
	}

	function get_colorScheme():Int return colorSchemeValue;
	function set_colorScheme(value:Int):Int {
		if (value != EnvironmentColorScheme.Light && value != EnvironmentColorScheme.Dark)
			throw "Style environment color scheme is unsupported";
		if (colorSchemeValue != value) {
			colorSchemeValue = value;
			revision++;
		}
		return value;
	}

	function get_pointer():Int return pointerValue;
	function set_pointer(value:Int):Int {
		if (value != EnvironmentPointer.Fine && value != EnvironmentPointer.Coarse)
			throw "Style environment pointer capability is unsupported";
		if (pointerValue != value) {
			pointerValue = value;
			revision++;
		}
		return value;
	}

	function get_hoverSupported():Bool return hoverSupportedValue;
	function set_hoverSupported(value:Bool):Bool {
		if (hoverSupportedValue != value) {
			hoverSupportedValue = value;
			revision++;
		}
		return value;
	}

	function get_textScale():Float return textScaleValue;
	function set_textScale(value:Float):Float {
		if (value <= 0.0)
			throw "Style environment text scale must be positive";
		if (textScaleValue != value) {
			textScaleValue = value;
			revision++;
		}
		return value;
	}

	function get_scrollbarVisibility():Int return scrollbarVisibilityValue;
	function set_scrollbarVisibility(value:Int):Int {
		if (value < 0 || value > 2) throw "Invalid scrollbar visibility";
		if (scrollbarVisibilityValue != value) {
			scrollbarVisibilityValue = value;
			revision++;
		}
		return value;
	}

	function get_reducedMotion():Bool return reducedMotionValue;
	function set_reducedMotion(value:Bool):Bool {
		if (reducedMotionValue != value) {
			reducedMotionValue = value;
			revision++;
		}
		return value;
	}

	function get_highContrast():Bool return highContrastValue;
	function set_highContrast(value:Bool):Bool {
		if (highContrastValue != value) {
			highContrastValue = value;
			revision++;
		}
		return value;
	}

	function refreshOrientation():Void
		orientation = width <= 0.0 || height <= 0.0 ? EnvironmentOrientation.Unknown
			: (width >= height ? EnvironmentOrientation.Landscape : EnvironmentOrientation.Portrait);
}

/** Typed environment query factories; no selector syntax or parser is involved. */
class Environment {
	/** Conditions on the viewport's width. */
	public static final width:EnvironmentDimension = new EnvironmentDimension(0);
	/** Conditions on the viewport's height. */
	public static final height:EnvironmentDimension = new EnvironmentDimension(1);
	/** Conditions on device pixels per logical pixel. */
	public static final pixelDensity:EnvironmentDimension = new EnvironmentDimension(2);
	/** Conditions on the user's text size multiplier. */
	public static final textScale:EnvironmentDimension = new EnvironmentDimension(3);

	/** While the viewport has the `EnvironmentOrientation` `value`. */
	public static function orientation(value:Int):EnvironmentCondition
		return EnvironmentCondition.orientation(value);

	/** While running on the platform `value`. */
	public static function platform(value:String):EnvironmentCondition
		return EnvironmentCondition.platform(value);

	/** While the system asks for the `EnvironmentColorScheme` `value`. */
	public static function colorScheme(value:Int):EnvironmentCondition
		return EnvironmentCondition.colorScheme(value);

	/** While the main pointer has the `EnvironmentPointer` precision `value`. */
	public static function pointer(value:Int):EnvironmentCondition
		return EnvironmentCondition.pointer(value);

	/** While the pointer can hover, or cannot when `value` is false. */
	public static function hoverSupported(value:Bool = true):EnvironmentCondition
		return EnvironmentCondition.hoverSupported(value);

	/** While the user asks for less motion, or does not. */
	public static function reducedMotion(value:Bool = true):EnvironmentCondition
		return EnvironmentCondition.reducedMotion(value);

	/** While the user asks for high contrast, or does not. */
	public static function highContrast(value:Bool = true):EnvironmentCondition
		return EnvironmentCondition.highContrast(value);
}

/** Stable color-scheme values for style environments. */
class EnvironmentColorScheme {
	/** A light appearance. */
	public static inline var Light:Int = 0;
	/** A dark appearance. */
	public static inline var Dark:Int = 1;
}

/** Typed environment predicate used by conditional style rules. */
class EnvironmentCondition {
	internal static inline var Width:Int = 0;
	internal static inline var Height:Int = 1;
	internal static inline var Density:Int = 2;
	internal static inline var TextScale:Int = 3;
	internal static inline var Orientation:Int = 4;
	internal static inline var Platform:Int = 5;
	internal static inline var ColorScheme:Int = 6;
	internal static inline var Pointer:Int = 7;
	internal static inline var HoverSupport:Int = 8;
	internal static inline var ReducedMotion:Int = 9;
	internal static inline var HighContrast:Int = 10;
	internal static inline var Less:Int = 0;
	internal static inline var LessOrEqual:Int = 1;
	internal static inline var Equal:Int = 2;
	internal static inline var GreaterOrEqual:Int = 3;
	internal static inline var Greater:Int = 4;

	final property:Int;
	final comparison:Int;
	final number:Float;
	final text:String;
	final flag:Bool;

	function new(property:Int, comparison:Int, number:Float, text:String, flag:Bool) {
		this.property = property;
		this.comparison = comparison;
		this.number = number;
		this.text = text;
		this.flag = flag;
	}

	internal function matches(environment:StyleEnvironment):Bool {
		if (environment == null)
			return false;
		if (property == 0) return compare(environment.width);
		if (property == 1) return compare(environment.height);
		if (property == 2) return compare(environment.pixelDensity);
		if (property == 3) return compare(environment.textScale);
		if (property == 4) return compare(cast environment.orientation);
		if (property == 5) return environment.platform == text;
		if (property == 6) return compare(cast environment.colorScheme);
		if (property == 7) return compare(cast environment.pointer);
		if (property == 8) return environment.hoverSupported == flag;
		if (property == 9) return environment.reducedMotion == flag;
		if (property == 10) return environment.highContrast == flag;
		return false;
	}

	function compare(value:Float):Bool {
		if (comparison == 0) return value < number;
		if (comparison == 1) return value <= number;
		if (comparison == 2) return value == number;
		if (comparison == 3) return value >= number;
		if (comparison == 4) return value > number;
		return false;
	}

	internal static function numeric(property:Int, comparison:Int, value:Float):EnvironmentCondition
		return new EnvironmentCondition(property, comparison, value, "", false);

	internal static function enumValue(property:Int, value:Int):EnvironmentCondition
		return new EnvironmentCondition(property, 2, value, "", false);

	internal static function boolean(property:Int, value:Bool):EnvironmentCondition
		return new EnvironmentCondition(property, 2, 0.0, "", value);

	internal static function orientation(value:Int):EnvironmentCondition
		return enumValue(4, value);

	internal static function platform(value:String):EnvironmentCondition
		return new EnvironmentCondition(5, 2, 0.0, value, false);

	internal static function colorScheme(value:Int):EnvironmentCondition
		return enumValue(6, value);

	internal static function pointer(value:Int):EnvironmentCondition
		return enumValue(7, value);

	internal static function hoverSupported(value:Bool = true):EnvironmentCondition
		return boolean(8, value);

	internal static function reducedMotion(value:Bool = true):EnvironmentCondition
		return boolean(9, value);

	internal static function highContrast(value:Bool = true):EnvironmentCondition
		return boolean(10, value);
}

/** Fluent numeric environment query entry point. */
class EnvironmentDimension {
	final property:Int;

	internal function new(property:Int)
		this.property = property;

	/** While the dimension is below `value`. */
	public function lessThan(value:Float):EnvironmentCondition
		return EnvironmentCondition.numeric(property, 0, value);

	/** While it is at most `value`. */
	public function lessOrEqual(value:Float):EnvironmentCondition
		return EnvironmentCondition.numeric(property, 1, value);

	/** While it is at least `value`. */
	public function atLeast(value:Float):EnvironmentCondition
		return EnvironmentCondition.numeric(property, 3, value);

	/** While it is above `value`. */
	public function greaterThan(value:Float):EnvironmentCondition
		return EnvironmentCondition.numeric(property, 4, value);
}

/** Stable orientation values for style environments. */
class EnvironmentOrientation {
	/** Not known, as before the first layout. */
	public static inline var Unknown:Int = 0;
	/** Taller than wide. */
	public static inline var Portrait:Int = 1;
	/** Wider than tall. */
	public static inline var Landscape:Int = 2;
}

/** Stable pointer capability values for style environments. */
class EnvironmentPointer {
	/** A precise pointer, such as a mouse. */
	public static inline var Fine:Int = 0;
	/** An imprecise one, such as a finger. */
	public static inline var Coarse:Int = 1;
}
