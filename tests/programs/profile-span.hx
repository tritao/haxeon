import haxeon.ProfileSpan;

function main():Int {
	ProfileSpan.begin("outer");
	ProfileSpan.begin("inner span with ünïcode");
	ProfileSpan.end("inner span with ünïcode");
	ProfileSpan.end("outer");
	return 42;
}
