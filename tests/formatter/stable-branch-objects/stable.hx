function main():Int {
	var chosen:Dynamic = if (ready) {} else {extra: 10};
	var other:Dynamic = if (ready) {name: "a"} else {name: "b"};
	if (ready) {
		count++;
	} else {
		count--;
	}
	return count;
}
