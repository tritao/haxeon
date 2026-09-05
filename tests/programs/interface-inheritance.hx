interface BasePlugin {
	function baseScore():Int;
}

interface Plugin extends BasePlugin {
	function score(value:Int):Int;
}

class SearchPlugin implements Plugin {
	public function baseScore():Int {
		return 2;
	}

	public function score(value:Int):Int {
		return value + 1;
	}
}

function consume(plugin:Plugin):Int {
	return plugin.baseScore() + plugin.score(40);
}

function main():Int {
	var plugin:Plugin = new SearchPlugin();
	return consume(plugin);
}
