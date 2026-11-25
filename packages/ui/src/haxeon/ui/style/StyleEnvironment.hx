package haxeon.ui.style;

import haxeon.ui.widgets.scroll.ScrollView.ScrollbarVisibility;

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

	/** Whether the viewport is taller or wider, from its size. */
	public var orientation(default, null):EnvironmentOrientation;
	var platformValue:String;

	/** The platform's name, such as "macos" or "web". */
	public var platform(get, set):String;
	var colorSchemeValue:EnvironmentColorScheme;

	/** The appearance the user asked the system for. */
	public var colorScheme(get, set):EnvironmentColorScheme;
	var pointerValue:EnvironmentPointer;

	/** How precise the main pointer is. */
	public var pointer(get, set):EnvironmentPointer;
	var hoverSupportedValue:Bool;

	/** Whether the pointer can hover. */
	public var hoverSupported(get, set):Bool;
	var textScaleValue:Float;

	/** The user's text size multiplier. */
	public var textScale(get, set):Float;
	var reducedMotionValue:Bool;

	/** Whether the user asked for less motion. */
	public var reducedMotion(get, set):Bool;
	var scrollbarVisibilityValue:ScrollbarVisibility = Auto;

	/** The system's scrollbar preference. */
	public var scrollbarVisibility(get, set):ScrollbarVisibility;
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

	function get_colorScheme():EnvironmentColorScheme return colorSchemeValue;
	function set_colorScheme(value:EnvironmentColorScheme):EnvironmentColorScheme {
		if (colorSchemeValue != value) {
			colorSchemeValue = value;
			revision++;
		}
		return value;
	}

	function get_pointer():EnvironmentPointer return pointerValue;
	function set_pointer(value:EnvironmentPointer):EnvironmentPointer {
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

	function get_scrollbarVisibility():ScrollbarVisibility return scrollbarVisibilityValue;
	function set_scrollbarVisibility(value:ScrollbarVisibility):ScrollbarVisibility {
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
	public static final width:EnvironmentDimension = new EnvironmentDimension(Width);
	/** Conditions on the viewport's height. */
	public static final height:EnvironmentDimension = new EnvironmentDimension(Height);
	/** Conditions on device pixels per logical pixel. */
	public static final pixelDensity:EnvironmentDimension = new EnvironmentDimension(PixelDensity);
	/** Conditions on the user's text size multiplier. */
	public static final textScale:EnvironmentDimension = new EnvironmentDimension(TextScale);

	/** While the viewport has the orientation `value`. */
	public static function orientation(value:EnvironmentOrientation):EnvironmentCondition
		return new EnvironmentCondition(Orientation(value));

	/** While running on the platform `value`. */
	public static function platform(value:String):EnvironmentCondition
		return new EnvironmentCondition(Platform(value));

	/** While the system asks for the appearance `value`. */
	public static function colorScheme(value:EnvironmentColorScheme):EnvironmentCondition
		return new EnvironmentCondition(ColorScheme(value));

	/** While the main pointer has the precision `value`. */
	public static function pointer(value:EnvironmentPointer):EnvironmentCondition
		return new EnvironmentCondition(Pointer(value));

	/** While the pointer can hover, or cannot when `value` is false. */
	public static function hoverSupported(value:Bool = true):EnvironmentCondition
		return new EnvironmentCondition(HoverSupported(value));

	/** While the user asks for less motion, or does not. */
	public static function reducedMotion(value:Bool = true):EnvironmentCondition
		return new EnvironmentCondition(ReducedMotion(value));

	/** While the user asks for high contrast, or does not. */
	public static function highContrast(value:Bool = true):EnvironmentCondition
		return new EnvironmentCondition(HighContrast(value));
}

/** The appearance the user asked the system for. */
enum EnvironmentColorScheme {
	/** A light appearance. */
	Light;
	/** A dark appearance. */
	Dark;
}

/** Whether the viewport is taller or wider. */
enum EnvironmentOrientation {
	/** Not known, as before the first layout. */
	Unknown;
	/** Taller than wide. */
	Portrait;
	/** Wider than tall. */
	Landscape;
}

/** How precise the main pointer is. */
enum EnvironmentPointer {
	/** A precise pointer, such as a mouse. */
	Fine;
	/** An imprecise one, such as a finger. */
	Coarse;
}

/** Typed environment predicate used by conditional style rules; made by `Environment`. */
class EnvironmentCondition {
	final test:EnvironmentTest;

	internal function new(test:EnvironmentTest)
		this.test = test;

	internal function matches(environment:StyleEnvironment):Bool {
		if (environment == null)
			return false;
		return switch test {
			case Compare(dimension, comparison, value): comparison.holds(switch dimension {
					case Width: environment.width;
					case Height: environment.height;
					case PixelDensity: environment.pixelDensity;
					case TextScale: environment.textScale;
				}, value);
			case Orientation(value): environment.orientation == value;
			case Platform(name): environment.platform == name;
			case ColorScheme(value): environment.colorScheme == value;
			case Pointer(value): environment.pointer == value;
			case HoverSupported(value): environment.hoverSupported == value;
			case ReducedMotion(value): environment.reducedMotion == value;
			case HighContrast(value): environment.highContrast == value;
		};
	}
}

/** What a condition tests. */
internal enum EnvironmentTest {
	Compare(dimension:EnvironmentMeasure, comparison:EnvironmentComparison, value:Float);
	Orientation(value:EnvironmentOrientation);
	Platform(name:String);
	ColorScheme(value:EnvironmentColorScheme);
	Pointer(value:EnvironmentPointer);
	HoverSupported(value:Bool);
	ReducedMotion(value:Bool);
	HighContrast(value:Bool);
}

/** A number of the environment a condition compares. */
internal enum EnvironmentMeasure {
	Width;
	Height;
	PixelDensity;
	TextScale;
}

/** How a condition compares a number. */
internal enum EnvironmentComparison {
	Less;
	LessOrEqual;
	GreaterOrEqual;
	Greater;

	public function holds(actual:Float, bound:Float):Bool
		return switch this {
			case Less: actual < bound;
			case LessOrEqual: actual <= bound;
			case GreaterOrEqual: actual >= bound;
			case Greater: actual > bound;
		};
}

/** Fluent numeric environment query entry point. */
class EnvironmentDimension {
	final measure:EnvironmentMeasure;

	internal function new(measure:EnvironmentMeasure)
		this.measure = measure;

	/** While the dimension is below `value`. */
	public function lessThan(value:Float):EnvironmentCondition
		return new EnvironmentCondition(Compare(measure, Less, value));

	/** While it is at most `value`. */
	public function lessOrEqual(value:Float):EnvironmentCondition
		return new EnvironmentCondition(Compare(measure, LessOrEqual, value));

	/** While it is at least `value`. */
	public function atLeast(value:Float):EnvironmentCondition
		return new EnvironmentCondition(Compare(measure, GreaterOrEqual, value));

	/** While it is above `value`. */
	public function greaterThan(value:Float):EnvironmentCondition
		return new EnvironmentCondition(Compare(measure, Greater, value));
}
