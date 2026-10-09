class GcIncrementalMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-gc-incremental.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
