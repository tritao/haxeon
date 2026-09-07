class DapFunctionProbe {
	static function main() {
		Sys.sleep(1.0);
		var worker = new DapFunctionWorker();
		for( value in 0...4 )
			worker.tick(value);
	}
}

class DapFunctionWorker {
	public function new() {}

	public function tick(value:Int):Int {
		return value * 2;
	}
}

class OtherFunctionWorker {
	public function new() {}

	public function tick(value:Int):Int {
		return value + 1;
	}
}
