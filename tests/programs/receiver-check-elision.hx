class ReceiverCheckProbe {
	public static var calls:Int = 0;
	public function new() {}
	public inline function value(n:Int):Int { calls++; return n; }
}

function missingReceiver():ReceiverCheckProbe {
	var value:Dynamic = null;
	return cast value;
}

function checked(receiver:ReceiverCheckProbe, branch:Bool):Int {
	var value = receiver.value(20);
	if (branch) value += receiver.value(1); else value += receiver.value(2);
	return value + receiver.value(19);
}

function main():Int {
	if (checked(new ReceiverCheckProbe(), false) != 41) return 1;
	try {
		checked(missingReceiver(), true);
		return 2;
	} catch (error:Dynamic) {}
	return ReceiverCheckProbe.calls == 3 ? 42 : 3;
}
