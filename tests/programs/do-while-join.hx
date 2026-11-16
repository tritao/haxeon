// A do-while body runs at least once, so what it leaves narrowed holds after the loop when no break or continue skips
// the rest of it: a local it always assigns a non-null value is known to be non-null there.
function label(count:Int):Int {
	var text:Null<String> = null, i = 0;
	do {
		text = 'item $i';
		i++;
	} while (i < count);
	return text.length;
}

function main():Int
	return label(3) == 6 ? 42 : 1;
