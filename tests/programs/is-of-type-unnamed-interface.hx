class Plain {
	public function new() {}
}

// An interface that only a type test names still answers it.
function main():Int {
	var plain:Dynamic = new Plain();
	if (typetests.Probe.tests(plain) || typetests.Probe.tests(1) || typetests.Probe.tests(null))
		return 1;
	if (typetests.Probe.downcasts(plain))
		return 2;
	return 42;
}
