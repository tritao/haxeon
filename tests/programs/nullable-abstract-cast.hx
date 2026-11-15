struct CastPayload {
	public var x:Int;
	public function new(x:Int) this.x = x;
}
abstract CastWrap(CastPayload) {
	public function new(x:Int) this = new CastPayload(x);
	public function read():Int return this.x;
}
function main():Int {
	var absent:Null<CastWrap>= null, present:Null<CastWrap>= new CastWrap(42);
	var ok:CastWrap = cast present;
	if (ok.read() != 42) return 1;
	try {
		var missing:CastWrap = cast absent;
		return missing.read();
	} catch (_:Dynamic) return 42;
}
