// Date's calendar fields, Haxe's constructor and DateTools.format behave as Haxe's; local time is the host's on every target.
function main():Int {
	var date = new Date(2024, 1, 29, 13, 5, 9);
	if (date.getFullYear() != 2024 || date.getMonth() != 1 || date.getDate() != 29 || date.getHours() != 13
		|| date.getMinutes() != 5 || date.getSeconds() != 9 || date.getDay() != 4)
		return 1;
	if (DateTools.format(date, "%Y%m%d-%H%M%S") != "20240229-130509"
		|| DateTools.format(date, "%Y-%m-%dT%H:%M:%S") != "2024-02-29T13:05:09")
		return 2;
	if (DateTools.format(date, "%e %I %p %j %a %B %%") != "29 01 PM 060 Thu February %"
		|| date.toString() != "2024-02-29 13:05:09")
		return 3;
	if (DateTools.getMonthDays(date) != 29 || DateTools.getMonthDays(new Date(2100, 1, 1, 0, 0, 0)) != 28)
		return 4;
	var later = DateTools.delta(date, DateTools.hours(11));
	if (later.getDate() != 1 || later.getMonth() != 2 || later.getHours() != 0)
		return 5;
	var epoch = Date.fromTime(0);
	if (epoch.getUTCFullYear() != 1970 || epoch.getUTCMonth() != 0 || epoch.getUTCDate() != 1 || epoch.getUTCDay() != 4)
		return 6;
	// Local fields are the UTC ones moved by the host's offset at that instant, and rebuild the same instant.
	var instant = Date.fromTime(1700000000000.0),
		local = instant.getDate() * 1440 + instant.getHours() * 60 + instant.getMinutes(),
		utc = instant.getUTCDate() * 1440 + instant.getUTCHours() * 60 + instant.getUTCMinutes(),
		rebuilt = new Date(instant.getFullYear(), instant.getMonth(), instant.getDate(), instant.getHours(),
			instant.getMinutes(), instant.getSeconds());
	if (instant.getUTCHours() != 22 || instant.getUTCMinutes() != 13 || instant.getSeconds() != 20
		|| rebuilt.getTime() != 1700000000000.0 || local - utc > 14 * 60 || utc - local > 12 * 60)
		return 7;
	return 42;
}
