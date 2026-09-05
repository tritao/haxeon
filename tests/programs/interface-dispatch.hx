interface Plugin {
	function score(value:Int):Int;
}

class SearchPlugin implements Plugin {
	public function score(value:Int):Int {
		return value + 2;
	}
}

function consume(plugin:Plugin):Int {
	return plugin.score(40);
}

function main():Int {
	var plugin:Plugin = new SearchPlugin();
	return consume(plugin);
}
