class ProfilerAllocationTarget {
	static function main():Void {
		Sys.sleep(1.0);
		var until = Sys.time() + 10.0, retained:Array<Array<Int>> = [], value = 0;
		while (Sys.time() < until) {
			var allocation = [for (index in 0...256) index + value];
			retained.push(allocation);
			if (retained.length > 128) retained.shift();
			value++;
		}
		Sys.println(value);
	}
}
