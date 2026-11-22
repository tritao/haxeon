package inventory;

using StringTools;

/** The stock as an aligned table, most valuable first. */
class Report {
	public static function render(stock:Stock):String {
		var items = stock.list();
		items.sort((a, b) -> Reflect.compare(b.value(), a.value()));
		var width = Lambda.fold(items, (item, widest) -> item.name.length > widest ? item.name.length : widest, 4);
		var out = new StringBuf();
		out.add("name".rpad(" ", width) + "  count     value\n");
		for (item in items) {
			var count = Std.string(item.count).lpad(" ", 5), value = money(item.value()).lpad(" ", 8);
			out.add(item.name.rpad(" ", width) + "  " + count + "  " + value + "\n");
		}
		return out.toString().rtrim();
	}

	public static function money(value:Float):String {
		var cents = Math.round(value * 100);
		return Std.int(cents / 100) + "." + Std.string(cents % 100).lpad("0", 2);
	}
}
