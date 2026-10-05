package nativekit.ui.settings;

import nativekit.ui.properties.PropertyOption;
import nativekit.ui.properties.PropertyType;
import nativekit.ui.properties.PropertyValue;

/**
 * Schema for one setting: where it lives, what it holds and its default.
 *
 * Paths are slash-separated lowercase segments such as
 * "interface/editor/fonts/main_font_size". The settings dialog files a setting
 * under its first two segments and groups rows by the segments in between.
 */
class SettingDefinition {
	public final path:String;
	public final segments:Array<String>;
	public final label:String;
	public final tooltip:Null<String>;
	public final type:PropertyType;
	public final defaultValue:PropertyValue;
	public final minimum:Null<Float>;
	public final maximum:Null<Float>;
	public final step:Null<Float>;
	public final unit:Null<String>;
	public final options:Array<PropertyOption>;
	public final advanced:Bool;
	public final restartRequired:Bool;
	public final internal:Bool;

	public function new(path:String, type:PropertyType, defaultValue:PropertyValue, ?settings:SettingOptions) {
		var config = settings == null ? new SettingOptions() : settings;
		if (!validPath(path))
			throw 'Setting paths are slash-separated lowercase segments: "$path"';
		switch (type) {
			case PropertyType.Custom(_):
				throw 'Settings cannot use custom property types: "$path"';
			case PropertyType.Enum:
				if (config.options == null || config.options.length == 0)
					throw 'Enum settings require options: "$path"';
			default:
		}
		if (config.minimum != null && config.maximum != null && config.minimum > config.maximum)
			throw 'Setting range is invalid: "$path"';
		if (config.step != null && config.step <= 0.0)
			throw 'Setting step must be positive: "$path"';
		this.path = path;
		this.segments = path.split("/");
		this.label = config.label == null ? labelFor(segments[segments.length - 1]) : config.label;
		this.tooltip = config.tooltip;
		this.type = type;
		this.minimum = config.minimum;
		this.maximum = config.maximum;
		this.step = config.step;
		this.unit = config.unit;
		this.options = config.options == null ? [] : config.options.copy();
		this.advanced = config.advanced;
		this.restartRequired = config.restartRequired;
		this.internal = config.internal;
		var keys:Map<String, Bool> = new Map();
		for (item in options) {
			if (item == null || keys.exists(item.key))
				throw 'Setting option keys must be unique: "$path"';
			keys.set(item.key, true);
		}
		var normalized = normalize(defaultValue);
		var error = normalized == null ? "Default value has the wrong type" : validate(normalized);
		if (error != null)
			throw '$error: "$path"';
		this.defaultValue = normalized;
	}

	/** Returns why the value cannot be stored, or null when it can. */
	public function validate(value:PropertyValue):Null<String> {
		var normalized = normalize(value);
		if (normalized == null)
			return "Value type does not match the setting";
		var number:Null<Float> = switch (normalized) {
			case Int(data): data;
			case Float(data): data;
			default: null;
		};
		if (number != null) {
			if (number != number || number - number != 0.0)
				return "Value must be a finite number";
			if (minimum != null && number < minimum)
				return "Value is below the minimum";
			if (maximum != null && number > maximum)
				return "Value is above the maximum";
		}
		return switch (normalized) {
			case Enum(key): option(key) == null ? "Unknown option" : null;
			default: null;
		};
	}

	/** The value in this setting's own shape (an Int given to a Float setting becomes a Float), or null on a type mismatch. */
	public function normalize(value:Null<PropertyValue>):Null<PropertyValue> {
		if (value == null)
			return null;
		return switch (type) {
			case PropertyType.Bool:
				switch (value) {
					case Bool(_): value;
					default: null;
				}
			case PropertyType.Int:
				switch (value) {
					case Int(_): value;
					default: null;
				}
			case PropertyType.Float:
				switch (value) {
					case Float(_): value;
					case Int(data): PropertyValue.Float(data);
					default: null;
				}
			case PropertyType.Text:
				switch (value) {
					case Text(data): data == null ? null : value;
					default: null;
				}
			case PropertyType.Enum:
				switch (value) {
					case Enum(data): data == null ? null : value;
					default: null;
				}
			case PropertyType.Custom(_): null;
		};
	}

	public function option(key:String):Null<PropertyOption> {
		for (item in options)
			if (item.key == key)
				return item;
		return null;
	}

	/** Turns "main_font_size" into "Main Font Size", "show_at_startup" into "Show at Startup" and "3d" into "3D". */
	public static function labelFor(segment:String):String {
		var words:Array<String> = [];
		for (word in segment.split("_")) {
			if (word.length == 0)
				continue;
			if (ACRONYMS.indexOf(word) >= 0)
				words.push(word.toUpperCase());
			else if (words.length > 0 && SMALL_WORDS.indexOf(word) >= 0)
				words.push(word);
			else
				words.push(word.charAt(0).toUpperCase() + word.substr(1));
		}
		return words.join(" ");
	}

	static final ACRONYMS:Array<String> = ["2d", "3d", "api", "cpu", "fps", "gpu", "id", "io", "lsp", "msaa", "ssh", "ssl", "tls", "ui", "url", "xr"];
	static final SMALL_WORDS:Array<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"];

	static function validPath(path:String):Bool {
		if (path == null || path.length == 0)
			return false;
		for (segment in path.split("/")) {
			if (segment.length == 0)
				return false;
			for (index in 0...segment.length) {
				var code = segment.charCodeAt(index);
				var lower = code >= "a".code && code <= "z".code;
				var digit = code >= "0".code && code <= "9".code;
				if (!lower && !digit && code != "_".code)
					return false;
			}
		}
		return true;
	}
}
