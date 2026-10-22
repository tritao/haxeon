import sys.thread.Thread;

@:hlNative("crash_test", "fault") extern function nativeFault(address:Int):Void;
@:hlNative("crash_test", "stack_overflow") extern function nativeOverflow():Void;

function resolveTarget():Void
	nativeFault(1);

function runPlanner():Void
	resolveTarget();

function main():Int {
	var mode = Sys.args()[0];
	if (mode == "main")
		runPlanner();
	else if (mode == "worker") {
		Thread.create(function() {
			try {
				runPlanner();
			} catch (error:Dynamic) {
				Sys.println("unexpected catch");
			}
		});
		while (true)
			Sys.sleep(1.0);
	} else if (mode == "overflow") {
		Thread.create(nativeOverflow);
		while (true)
			Sys.sleep(1.0);
	} else {
		Sys.println("ready");
		while (true)
			Sys.sleep(1.0);
	}
	return 0;
}
