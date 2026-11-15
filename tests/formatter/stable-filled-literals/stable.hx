class A {
	function f() {
		var body = [
			LocalGet(0), I32Const(1), I32Add, LocalSet(2), LocalGet(3), I32Const(4), I32Mul, LocalSet(5), LocalGet(6),
			I32Const(7),
			I32Sub, LocalSet(8), // a trailing comment
			LocalGet(9), Return
		];
		var table = [
			1, 2, 3,
			4, 5, 6
		];
	}
}
