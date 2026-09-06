function caughtThrow():Int {
	try {
		throw "caught-probe";
	} catch (error:Int) {
		return 0;
	} catch (error:String) {
		return 12;
	}
}

function uncaughtThrow():Int {
	throw "uncaught-probe";
}

function main():Void {
	Sys.sleep(1.0);
	var marker = caughtThrow();
	if (marker != 12)
		throw "bad-catch";
	uncaughtThrow();
}
