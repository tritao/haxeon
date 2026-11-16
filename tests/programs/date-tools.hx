// Date's calendar fields, Haxe's constructor and DateTools.format behave as Haxe's; local time is the host's (UTC on Wasm).
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
	return 42;
}
