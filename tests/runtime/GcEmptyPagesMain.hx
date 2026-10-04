class GcEmptyPagesMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-gc-empty-pages.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
