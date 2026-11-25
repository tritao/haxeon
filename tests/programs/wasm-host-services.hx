// trace, Sys.println, Date.now and Sys.args reach the host through the HaxeonHost interface on both Wasm backends; (@formatter:off: the expected trace names line 4)
// the harness checks the text and timestamp the host saw.
function main():Int {
	trace("host trace");
	var now = Date.now().getTime();
	Sys.println(now > 1.6e12 ? "host println" : "host date");
	Sys.stdout().writeString("stdout λ");
	Sys.stdout().flush();
	Sys.stderr().writeString("stderr 雪");
	Sys.stderr().flush();
	#if !wasmgc
	// The harness starts the program with these two arguments.
	if (Sys.args().join("|") != "--page=controls|λ 雪")
		return 2;
	#end
	var start = Sys.monotonicTime();
	var end = Sys.monotonicTime();
	return Math.isFinite(start) && Math.isFinite(end) && end >= start ? 42 : 1;
}
