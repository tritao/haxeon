class Main {
	static function control():Void {
		var total = 0;
		for (i in 0...4) {
			try {
				total += i;
				if (i == 1)
					continue;
				if (i == 2)
					throw "stop";
			} catch (error:String) {
				total += 10;
				break;
			}
			total++;
		}
		Sys.println("control:" + total);
	}

	static function main():Void {
		control();
	}
}
