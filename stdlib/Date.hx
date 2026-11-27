/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

#if wasm
/**
 * A point in time, in milliseconds since the Unix epoch, read from the Wasm host. Local time is the host's: the host gives
 * the time zone's offset from UTC at each instant (HaxeonHost.date_timezone_offset), so daylight saving applies as it did
 * then.
 */
class Date {
	static inline final DAY = 86400000.0;
	static inline final MINUTE = 60000.0;

	var time:Float;

	/** The local time `year`-`month`-`day` `hour`:`min`:`sec` (months from 0), as Haxe's Date. */
	public function new(year:Int, month:Int, day:Int, hour:Int, min:Int, sec:Int) {
		var wall = (daysFromCivil(year, month + 1, day) * 24.0 * 3600.0 + hour * 3600.0 + min * 60.0 + sec) * 1000.0;
		// The offset that applies is the one at the instant itself, which the wall time only approximates; one more
		// step settles it, as mktime does, except in the hour a clock change skips or repeats.
		var guess = wall - offsetAt(wall);
		time = wall - offsetAt(guess);
	}

	/** The current date and time. */
	public static function now():Date
		return fromTime(haxeon.wasm.HaxeonHost.date_now());

	/** The date `t` milliseconds after the Unix epoch. */
	public static function fromTime(t:Float):Date {
		var date = new Date(1970, 0, 1, 0, 0, 0);
		date.time = t;
		return date;
	}

	/** The date as milliseconds since the Unix epoch. */
	public function getTime():Float
		return time;

	/** The year, in local time, as four digits. */
	public function getFullYear():Int
		return civil(local())[0];

	/** The month, in local time, from 0 for January to 11. */
	public function getMonth():Int
		return civil(local())[1] - 1;

	/** The day of the month, in local time, from 1. */
	public function getDate():Int
		return civil(local())[2];

	/** The day of the week, 0 for Sunday. */
	public function getDay():Int
		return weekday(local());

	/** The hour, in local time, from 0 to 23. */
	public function getHours():Int
		return hours(local());

	/** The minutes, in local time, from 0 to 59. */
	public function getMinutes():Int
		return minutes(local());

	/** The seconds, in local time, from 0 to 59. */
	public function getSeconds():Int
		return seconds(local());

	/** The year, in UTC, as four digits. */
	public function getUTCFullYear():Int
		return civil(time)[0];

	/** The month, in UTC, from 0 for January to 11. */
	public function getUTCMonth():Int
		return civil(time)[1] - 1;

	/** The day of the month, in UTC, from 1. */
	public function getUTCDate():Int
		return civil(time)[2];

	/** The day of the week, in UTC, 0 for Sunday. */
	public function getUTCDay():Int
		return weekday(time);

	/** The hour, in UTC, from 0 to 23. */
	public function getUTCHours():Int
		return hours(time);

	/** The minutes, in UTC, from 0 to 59. */
	public function getUTCMinutes():Int
		return minutes(time);

	/** The seconds, in UTC, from 0 to 59. */
	public function getUTCSeconds():Int
		return seconds(time);

	/** "YYYY-MM-DD HH:MM:SS", as Haxe's. */
	public function toString():String
		return DateTools.format(this, "%Y-%m-%d %H:%M:%S");

	/** The time as the host's clock on the wall shows it, counted as if it were UTC. */
	function local():Float
		return time + offsetAt(time);

	/** How far the host's local time is ahead of UTC at `t`, in milliseconds. */
	static function offsetAt(t:Float):Float
		return haxeon.wasm.HaxeonHost.date_timezone_offset(t) * MINUTE;

	static function days(t:Float):Float
		return Math.floor(t / DAY);

	static function millisecondsOfDay(t:Float):Float
		return t - days(t) * DAY;

	static function weekday(t:Float):Int {
		var weekday = (days(t) + 4.0) % 7.0;
		return Std.int(weekday < 0 ? weekday + 7.0 : weekday);
	}

	static function hours(t:Float):Int
		return Std.int(Math.floor(millisecondsOfDay(t) / 3600000.0));

	static function minutes(t:Float):Int
		return Std.int(Math.floor(millisecondsOfDay(t) / MINUTE)) % 60;

	static function seconds(t:Float):Int
		return Std.int(Math.floor(millisecondsOfDay(t) / 1000.0)) % 60;

	/** Year, month (1 to 12) and day of the date at `t` (Howard Hinnant's civil-from-days). */
	static function civil(t:Float):Array<Int> {
		var z = days(t) + 719468.0,
			era = Math.floor(z / 146097.0),
			doe = z - era * 146097.0,
			yoe = Math.floor((doe - Math.floor(doe / 1460.0) + Math.floor(doe / 36524.0) - Math.floor(doe / 146096.0))
				/ 365.0),
			doy = doe - (365.0 * yoe + Math.floor(yoe / 4.0) - Math.floor(yoe / 100.0)),
			mp = Math.floor((5.0 * doy + 2.0) / 153.0),
			day = doy - Math.floor((153.0 * mp + 2.0) / 5.0) + 1.0,
			month = mp < 10.0 ? mp + 3.0 : mp - 9.0,
			year = yoe + era * 400.0 + (month <= 2.0 ? 1.0 : 0.0);
		return [Std.int(year), Std.int(month), Std.int(day)];
	}

	/** Days from 1970-01-01 to `year`-`month`-`day`, month from 1 (Howard Hinnant's days-from-civil). */
	static function daysFromCivil(year:Int, month:Int, day:Int):Float {
		var y = month <= 2 ? year - 1.0 : year * 1.0,
			era = Math.floor(y / 400.0),
			yoe = y - era * 400.0,
			doy = Math.floor((153.0 * (month > 2 ? month - 3.0 : month + 9.0) + 2.0) / 5.0) + day - 1.0,
			doe = yoe * 365.0 + Math.floor(yoe / 4.0) - Math.floor(yoe / 100.0) + doy;
		return era * 146097.0 + doe - 719468.0;
	}
}
#else
/** A date and time, to the second, in the host's local time zone or in UTC. Months count from 0. */
extern abstract Date(hl.Abstract<"realtime_date">) {
	/** The local time `year`-`month`-`day` `hour`:`min`:`sec` (months from 0), as Haxe's Date. */
	@:hlNative("haxeon_runtime", "__date_new")
	public function new(year:Int, month:Int, day:Int, hour:Int, min:Int, sec:Int);

	/** The current date and time. */
	@:hlNative("haxeon_runtime", "__date_now")
	public static function now():Date;

	/** The date as milliseconds since the Unix epoch. */
	@:hlNative("haxeon_runtime", "__date_get_time")
	public function getTime():Float;

	/** The date `t` milliseconds after the Unix epoch. */
	@:hlNative("haxeon_runtime", "__date_from_time")
	public static function fromTime(t:Float):Date;

	/** The year, in local time, as four digits. */
	@:hlNative("haxeon_runtime", "__date_get_full_year") public function getFullYear():Int;

	/** The month, in local time, from 0 for January to 11. */
	@:hlNative("haxeon_runtime", "__date_get_month") public function getMonth():Int;

	/** The day of the month, in local time, from 1. */
	@:hlNative("haxeon_runtime", "__date_get_date") public function getDate():Int;

	/** The day of the week, in local time, 0 for Sunday. */
	@:hlNative("haxeon_runtime", "__date_get_day") public function getDay():Int;

	/** The hour, in local time, from 0 to 23. */
	@:hlNative("haxeon_runtime", "__date_get_hours") public function getHours():Int;

	/** The minutes, in local time, from 0 to 59. */
	@:hlNative("haxeon_runtime", "__date_get_minutes") public function getMinutes():Int;

	/** The seconds, in local time, from 0 to 59. */
	@:hlNative("haxeon_runtime", "__date_get_seconds") public function getSeconds():Int;

	/** The year, in UTC, as four digits. */
	@:hlNative("haxeon_runtime", "__date_get_utc_full_year") public function getUTCFullYear():Int;

	/** The month, in UTC, from 0 for January to 11. */
	@:hlNative("haxeon_runtime", "__date_get_utc_month") public function getUTCMonth():Int;

	/** The day of the month, in UTC, from 1. */
	@:hlNative("haxeon_runtime", "__date_get_utc_date") public function getUTCDate():Int;

	/** The day of the week, in UTC, 0 for Sunday. */
	@:hlNative("haxeon_runtime", "__date_get_utc_day") public function getUTCDay():Int;

	/** The hour, in UTC, from 0 to 23. */
	@:hlNative("haxeon_runtime", "__date_get_utc_hours") public function getUTCHours():Int;

	/** The minutes, in UTC, from 0 to 59. */
	@:hlNative("haxeon_runtime", "__date_get_utc_minutes") public function getUTCMinutes():Int;

	/** The seconds, in UTC, from 0 to 59. */
	@:hlNative("haxeon_runtime", "__date_get_utc_seconds") public function getUTCSeconds():Int;

	/** "YYYY-MM-DD HH:MM:SS" in local time, as Haxe's. */
	@:hlNative("haxeon_runtime", "__date_to_string")
	public function toString():String;
}
#end
