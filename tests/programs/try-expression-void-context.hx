class Log {
	public static var entries = 0;

	public static function note():Void {
		entries++;
	}
}

function risky(fail:Bool):Int {
	if (fail)
		throw "failed";
	return 5;
}

function run(callback:() -> Void):Void {
	callback();
}

function main():Int {
	// The value of each try expression is discarded, so its branches may differ in type.
	run(() -> try risky(true) catch (error:Dynamic) {
		Log.note();
	});
	run(() -> try risky(false) catch (error:Dynamic) {
		Log.note();
	});
	run(() -> try risky(true) catch (error:Dynamic) Log.note());
	run(() -> try risky(true) catch (error:Dynamic) 0);
	var kept = try risky(true) catch (error:Dynamic) 40;
	return kept + Log.entries;
}
