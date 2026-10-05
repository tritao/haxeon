class GcAllocationPathsMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-gc-allocation-paths.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
