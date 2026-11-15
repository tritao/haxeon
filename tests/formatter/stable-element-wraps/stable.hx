class A {
	function f() {
		row([
			explorer.keyed("one",
				explorer.colorTile("Navigation · 1", UiExplorer.color(0.24, 0.48, 0.77), 1.0, extraArgument)),
			explorer.keyed("two", explorer.colorTile("Editor · 3", UiExplorer.color(0.39, 0.34, 0.72), 3.0))
		], explorer.rowStyle(8.0));
		switch value {
			case Call(name, arguments, span) if (StringTools.endsWith(name, ".set") && arguments.length == 2
				&& pathReceiver(Variable(name, span))):
				x();
			default:
		}
		items.push(explorer.keyed("copy",
			explorer.caption("Scroll inside the list. ListView materializes only the viewport window and a small overscan")));
	}
}
