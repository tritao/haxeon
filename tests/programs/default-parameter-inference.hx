function choose(?enabled = true):Int {
	return enabled ? 42 : 0;
}

function main():Int {
	return choose() + choose(false);
}
