class Cancelled {
	public function new() {}
}

function work(kind:Int):Void {
	if (kind == 1)
		throw new Cancelled();
	if (kind == 2)
		throw "text";
}

function main():Int {
	var total = 0;
	for (kind in [0, 2, 2])
		try
			work(kind)
		catch (cancelled:Cancelled)
			throw cancelled
		catch (_:String) total += 20 catch (_:Dynamic) {}
	try {
		work(1);
	} catch (_:Cancelled) {
		total += 2;
	}
	return total;
}
