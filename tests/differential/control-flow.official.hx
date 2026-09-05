class Main {
	static function main():Void {
		var value = 0;
		var index = 0;
		while (index < 7) {
			if (index == 3) {
				index++;
				continue;
			}
			value += index;
			index++;
		}
		Sys.exit(value);
	}
}
