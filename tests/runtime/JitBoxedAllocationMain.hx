class JitBoxedAllocationMain {
	static function main():Void {
		var status = Sys.command("bash", ["tests/integration/test-jit-boxed-allocation.sh"]);
		if (status != 0)
			Sys.exit(status);
	}
}
