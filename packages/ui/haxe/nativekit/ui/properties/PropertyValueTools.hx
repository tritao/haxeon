package nativekit.ui.properties;

/** Formatting and equality helpers shared by property controls. */
class PropertyValueTools {
	public static function same(first:Null<PropertyValue>, second:Null<PropertyValue>):Bool {
		if (first == null || second == null)
			return first == second;
		return switch ([first, second]) {
			case [Unavailable, Unavailable] | [Mixed, Mixed]: true;
			case [Bool(a), Bool(b)]: a == b;
			case [Int(a), Int(b)]: a == b;
			case [Float(a), Float(b)]: a == b;
			case [Text(a), Text(b)] | [Enum(a), Enum(b)]: a == b;
			case [Custom(typeA, a), Custom(typeB, b)]: typeA == typeB && a == b;
			default: false;
		};
	}

	public static function display(value:Null<PropertyValue>, mixedText:String = "—"):String {
		if (value == null)
			return "";
		return switch (value) {
			case Unavailable: "";
			case Mixed: mixedText;
			case Bool(data): data ? "true" : "false";
			case Int(data): Std.string(data);
			case Float(data): formatFloat(data);
			case Text(data) | Enum(data): data;
			case Custom(_, data): data == null ? "" : Std.string(data);
		};
	}

	public static function editableText(value:Null<PropertyValue>):String {
		if (value == null)
			return "";
		return switch (value) {
			case Text(data): data;
			case Enum(data): data;
			case Bool(data): data ? "true" : "false";
			case Int(data): Std.string(data);
			case Float(data): formatFloat(data);
			case Unavailable | Mixed: "";
			case Custom(_, data): data == null ? "" : Std.string(data);
		};
	}

	public static function parse(type:PropertyType, text:String):Null<PropertyValue> {
		var value = text == null ? "" : StringTools.trim(text);
		var integerValue = Std.parseInt(value);
		var floatValue = Std.parseFloat(value);
		return switch (type) {
			case Text: PropertyValue.Text(value);
			case Enum: PropertyValue.Enum(value);
			case Custom(_): null;
			case Bool: value == "true" ? PropertyValue.Bool(true) :
				value == "false" ? PropertyValue.Bool(false) : null;
			case Int: integerValue == null || Std.string(integerValue) != value
				? null : PropertyValue.Int(integerValue);
			case Float: value.length == 0 || !finite(floatValue)
				? null : PropertyValue.Float(floatValue);
		};
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;

	/** Keep editor fields readable without changing the stored numeric value. */
	static function formatFloat(value:Float):String {
		if (!finite(value) || Math.abs(value) > 2000.0 ||
			(value != 0.0 && Math.abs(value) < 0.000001))
			return Std.string(value);
		var scaled = Math.round(Math.abs(value) * 1000000.0);
		var whole = Std.int(scaled / 1000000);
		var fraction = scaled % 1000000;
		var result = (value < 0.0 ? "-" : "") + Std.string(whole);
		if (fraction == 0)
			return result;
		var digits = StringTools.lpad(Std.string(fraction), "0", 6);
		while (StringTools.endsWith(digits, "0"))
			digits = digits.substr(0, digits.length - 1);
		return result + "." + digits;
	}
}
