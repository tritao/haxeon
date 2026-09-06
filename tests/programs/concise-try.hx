function fail():Void {
	throw "failure";
}

function main():Int {
	try
		fail()
	catch (error:String) {
		return 42;
	}
}
