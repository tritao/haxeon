class GcMarkClaimMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-gc-mark-claim.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
