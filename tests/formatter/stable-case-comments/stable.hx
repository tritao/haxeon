class A {
	function f() {
		scalarAlignLimit = switch architecture {
			case "x86": windows ? 8 : 4;
			// Wasm32 and ARM align 64-bit scalars to 8.
			default: 8;
		};
		switch k {
			case A:
				x();
			// next case
			case B:
				y();
			default:
		}
	}
}
