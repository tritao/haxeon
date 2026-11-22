import inventory.Item;
import inventory.Parser;
import inventory.Report;
import inventory.Stock;

/** A small program of the kind perf-guard's small-project build measures: stdlib collections, strings and sys. */
class Main {
	static function main() {
		var stock = new Stock();
		for (item in Parser.parse("apple,fruit,3,0.5\npear,fruit,2,0.75\nleek,vegetable,5,1.2\nbread,bakery,1,2.5\n"))
			stock.add(item);
		var arguments = Sys.args();
		if (arguments.length > 0 && sys.FileSystem.exists(arguments[0]))
			for (item in Parser.parse(sys.io.File.getContent(arguments[0])))
				stock.add(item);
		stock.remove("pear", 1);
		Sys.println(Report.render(stock));
		Sys.println('categories: ${[for (category in stock.categories()) category].join(", ")}');
		Sys.println('total: ${Report.money(stock.total())}');
	}
}
