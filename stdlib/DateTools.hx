/** Haxe's DateTools: formatting and arithmetic on Date values. */
class DateTools {
	static final dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
	static final monthNames = [
		"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
		"December"
	];

	/**
	 * `d` written by the `%` conversions of `f`, as Haxe's DateTools.format: %a %A %b %B %C %d %D %e %F %h %H %I %j %k %l
	 * %m %M %n %p %r %R %s %S %t %T %u %w %y %Y and %%. An unknown conversion throws.
	 */
	public static function format(d:Date, f:String):String {
		var text = new StringBuf(), index = 0;
		while (index < f.length) {
			var percent = f.indexOf("%", index);
			if (percent < 0) {
				text.add(f.substr(index));
				break;
			}
			text.add(f.substr(index, percent - index));
			if (percent + 1 >= f.length)
				throw "Date.format: a lone % ends the format";
			text.add(conversion(d, f.charAt(percent + 1)));
			index = percent + 2;
		}
		return text.toString();
	}

	static function conversion(d:Date, code:String):String
		return switch code {
			case "a": dayNames[d.getDay()].substr(0, 3);
			case "A": dayNames[d.getDay()];
			case "b", "h": monthNames[d.getMonth()].substr(0, 3);
			case "B": monthNames[d.getMonth()];
			case "C": pad(Std.int(d.getFullYear() / 100), "0");
			case "d": pad(d.getDate(), "0");
			case "D": format(d, "%m/%d/%y");
			case "e": pad(d.getDate(), " ");
			case "F": format(d, "%Y-%m-%d");
			case "H": pad(d.getHours(), "0");
			case "k": pad(d.getHours(), " ");
			case "I": pad(twelveHour(d), "0");
			case "l": pad(twelveHour(d), " ");
			case "j": padThree(dayOfYear(d));
			case "m": pad(d.getMonth() + 1, "0");
			case "M": pad(d.getMinutes(), "0");
			case "n": "\n";
			case "p": d.getHours() > 11 ? "PM" : "AM";
			case "r": format(d, "%I:%M:%S %p");
			case "R": format(d, "%H:%M");
			case "s": Std.string(Std.int(d.getTime() / 1000));
			case "S": pad(d.getSeconds(), "0");
			case "t": "\t";
			case "T": format(d, "%H:%M:%S");
			case "u": Std.string(d.getDay() == 0 ? 7 : d.getDay());
			case "w": Std.string(d.getDay());
			case "y": pad(d.getFullYear() % 100, "0");
			case "Y": Std.string(d.getFullYear());
			case "%": "%";
			default: throw 'Date.format %$code- not implemented yet.';
		};

	static function pad(value:Int, filler:String):String
		return value < 10 ? filler + value : Std.string(value);

	static function padThree(value:Int):String
		return value < 10 ? "00" + value : value < 100 ? "0" + value : Std.string(value);

	static function twelveHour(d:Date):Int {
		var hour = d.getHours() % 12;
		return hour == 0 ? 12 : hour;
	}

	static function dayOfYear(d:Date):Int {
		var day = d.getDate();
		for (month in 0...d.getMonth())
			day += getMonthDays(new Date(d.getFullYear(), month, 1, 0, 0, 0));
		return day;
	}

	/** `d` moved by `t` milliseconds. */
	public static function delta(d:Date, t:Float):Date
		return Date.fromTime(d.getTime() + t);

	/** The number of days in the month of `d`. */
	public static function getMonthDays(d:Date):Int {
		var month = d.getMonth(), year = d.getFullYear();
		if (month != 1)
			return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
		var leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
		return leap ? 29 : 28;
	}

	/** `n` seconds in milliseconds, the unit `Date.getTime` counts in. */
	public static inline function seconds(n:Float):Float
		return n * 1000.0;

	/** `n` minutes in milliseconds. */
	public static inline function minutes(n:Float):Float
		return n * 60.0 * 1000.0;

	/** `n` hours in milliseconds. */
	public static inline function hours(n:Float):Float
		return n * 60.0 * 60.0 * 1000.0;

	/** `n` days of 24 hours in milliseconds. */
	public static inline function days(n:Float):Float
		return n * 24.0 * 60.0 * 60.0 * 1000.0;
}
