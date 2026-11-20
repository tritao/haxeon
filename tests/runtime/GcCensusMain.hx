class GcCensusMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-gc-census.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
