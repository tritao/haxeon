class A {
	function f() {
		if (a) x();
		if (a)
			x();
		else
			y();
		if (a) if (b) z();
		for (i in 0...3) for (j in 0...3) {
			k(i, j);
		}
		while (c) step();
		var v = if (a) 1 else 2;
		if (a) {
			x();
		} else if (b)
			y();
		else {
			z();
		}
		if (a) // why
			x();
		do {
			x();
		} while (c);
		return;
	}
}
