class DapCliProbe { // @formatter:off: the DAP tests address this file by line
	static function main() {
		for (index in 0...250) {
			var marker = index * 2;
			if (marker == 498)
				Sys.println("DAP probe completed");
			Sys.sleep(0.02);
		}
	}
}
