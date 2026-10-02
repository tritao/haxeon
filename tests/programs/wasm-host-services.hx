// trace, Sys.println and Date.now reach the host through the HaxeonHost interface on both Wasm backends;
// the harness checks the text and timestamp the host saw.
function main():Int {
	trace("host trace");
	var now = Date.now().getTime();
	Sys.println(now > 1.6e12 ? "host println" : "host date");
	Sys.stdout().writeString("stdout λ");
	Sys.stdout().flush();
	Sys.stderr().writeString("stderr 雪");
	Sys.stderr().flush();
	return 42;
}
