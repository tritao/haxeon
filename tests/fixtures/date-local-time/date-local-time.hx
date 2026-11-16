// Local time is the host's on every target. The parity suite runs this with TZ=Asia/Kolkata (UTC+5:30, no daylight
// saving), where 2023-11-14 22:13:20 UTC is 03:43:20 the next morning; a target that read local time as UTC would not.
function main():Int {
	var instant = Date.fromTime(1700000000000.0);
	if (instant.getFullYear() != 2023 || instant.getMonth() != 10 || instant.getDate() != 15 || instant.getDay() != 3
		|| instant.getHours() != 3 || instant.getMinutes() != 43 || instant.getSeconds() != 20)
		return 1;
	if (instant.getUTCDate() != 14 || instant.getUTCHours() != 22 || instant.getUTCMinutes() != 13)
		return 2;
	if (new Date(2023, 10, 15, 3, 43, 20).getTime() != 1700000000000.0
		|| DateTools.format(instant, "%Y-%m-%d %H:%M") != "2023-11-15 03:43")
		return 3;
	return 42;
}
