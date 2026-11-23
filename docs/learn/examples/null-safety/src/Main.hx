function label(name:Null<String>):String {
	if (name == null)
		return "anonymous";
	return name.toUpperCase();
}

function main():Void {
	final names = ["Ada"];
	Sys.println(label(names.pop()));
	Sys.println(label(names.pop()));
	final counts:Map<String, Int> = ["Ada" => 3];
	final count = counts.get("Lin") ?? 0;
	Sys.println('Lin: $count');
}
