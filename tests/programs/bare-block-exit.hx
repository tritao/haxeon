// A bare block always runs, so a function can end in one that returns, and a use after one that throws is never reached.
function endsInBlock(value:Int):Int {
	{
		return value + 1;
	}
}

function throwsBeforeUse(fail:Bool):Int {
	var result:Int;
	{
		if (fail)
			throw "bare block";
		result = 41;
	}
	return result + 1;
}

function throwsThenUse():Int {
	var never:Int;
	{
		throw "bare block";
	}
	return never;
}

function main():Int {
	var thrown = false;
	try
		throwsBeforeUse(true)
	catch (message:String)
		thrown = message == "bare block";
	try
		throwsThenUse()
	catch (message:String)
		thrown = thrown && message == "bare block";
	{
		return endsInBlock(40) == 41 && thrown && throwsBeforeUse(false) == 42 ? 42 : 1;
	}
}
