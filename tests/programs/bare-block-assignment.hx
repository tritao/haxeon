// A bare block always runs, so a local it assigns is assigned after it, with or without a defer inside.
function main():Int {
	var count = 0, rounds = 0;
	while (true) {
		var done:Bool;
		{
			count++;
			done = count > 2;
		}
		if (done)
			break;
		rounds++;
	}
	var other:Bool;
	{
		defer count++;
		other = true;
	}
	var viaIf:Int;
	if (true)
		viaIf = 5;
	return other && rounds == 2 && count == 4 && viaIf == 5 ? 42 : 1;
}
