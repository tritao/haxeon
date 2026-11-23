package valuescope.other;

enum abstract Mode(Int) to Int {
	var Fast = 7;
	var Slow = 8;
}

enum Signal {
	Go;
	Stop(code:Int);
}
