function explode():Bool {
	trace("unexpected");
	return true;
}

function main():Int {
	if (false && explode())
		return 0;
	if (true || explode())
		return 42;
	return 0;
}
