import modulevars.Merged;
import modulevars.Settings;
import modulevars.Settings.base;

final greeting = "hello";
var total = 0;

function add(value:Int):Void
	total += value;

function main():Int {
	var hits = 1000; // a local, not the module-level variable
	Settings.record(); // hits = 2
	new modulevars.Settings.Counter().advance(); // hits = 2 + 5 + 3 = 10
	Settings.hits += 1; // 11
	var shadow = new modulevars.Settings.Shadow().bump(); // 102, and Settings.hits stays 11
	add(Settings.hits);
	add(base);
	add(Settings.derived); // 21
	if (Settings.names.join(",") != "record" || greeting != "hello" || Merged.label + "/" + Merged.own != "merged/own"
		|| modulevars.Merged.own != "module"
		|| shadow != 102 || hits != 1000)
		return 1;
	return total == 11 + 10 + 21 ? 42 : 2;
}
