interface Base {
	function baseScore():Int;
}

interface Plugin extends Base {
	function score():Int;
}

class SearchPlugin implements Plugin {
	public function baseScore():Int {
		return 5;
	}

	public function score():Int {
		return 9;
	}
}

function consume(plugin:Base):Int {
	return plugin.baseScore();
}

function main():Int {
	var plugin:Plugin = new SearchPlugin();
	return consume(plugin);
}
