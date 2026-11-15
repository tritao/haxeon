class A {
	function f() {
		var v = switch index {
			case 0: value.x0;
			case 1: value.y0;
			default: 0;
		};
		var w = switch k {
			case A: {x: 1};
			default: {y: 2};
		};
		switch kind {
			case EffectKind.Custom: {}
			case EffectKind.Blur: {
				blur();
			}
			case EffectKind.Shadow:
				shadow();
				more();
			case EffectKind.Glow: glow();
				after();
			default:
		}
	}
}
