class AuditBase {
	public function new() {}
}

class AuditChild extends AuditBase {
	public function new() {
		super();
	}
}

enum AuditKind {
	Number;
	Text;
	DynamicValue;
}

enum abstract AuditShape(String) to String {
	var IntegerShape = "i32";
	var ReferenceShape = "ref";
}

class Main {
	static function auditShape(kind:AuditKind):AuditShape
		return switch kind {
			case Number: AuditShape.IntegerShape;
			default: AuditShape.ReferenceShape;
		};

	static function auditRepresentative(kind:AuditKind):AuditKind
		return switch auditShape(kind) {
			case AuditShape.IntegerShape: Number;
			case AuditShape.ReferenceShape: DynamicValue;
			default: throw "unknown shape";
		};

	static function auditMake():AuditBase {
		return new AuditChild();
	}

	static function auditDynamic(value:Dynamic):Int {
		return 42;
	}

	static function auditFail(value:Bool):Void {
		if (value)
			throw "stop";
	}

	static function auditAfterCatch():Int {
		var value = 1;
		try {
			if (value == 1) {
				value = 42;
				throw "stop";
			}
		} catch (error:Dynamic) {}
		return value;
	}

	static function auditBeforeStore():Int {
		var value = 42;
		try {
			auditFail(true);
			value = 1;
		} catch (error:Dynamic) {}
		return value;
	}

	static function auditShadow():Int {
		var value = 1;
		try {
			if (value == 1) {
				value = 42;
				throw "stop";
			}
		} catch (error:Dynamic) {
			if (true) {
				var value = 9;
				value++;
			}
			return value;
		}
		return 0;
	}

	static function auditPostfix():Int {
		var value = 41;
		try {
			if (value > 0) {
				var old = value++;
				throw "stop";
			}
		} catch (error:Dynamic) {
			return value;
		}
		return 0;
	}

	static function auditUninitialized():Int {
		var value:Int;
		try {
			value = 42;
		} catch (error:Dynamic) {
			throw error;
		}
		return value;
	}

	static function auditLoopCell():Int {
		for (value in [1]) {
			try {
				value = 42;
				throw "stop";
			} catch (error:Dynamic) {}
			return value;
		}
		return 0;
	}

	static function auditCatchCell():Int {
		try {
			throw 1;
		} catch (value:Int) {
			try {
				value = 42;
				throw "stop";
			} catch (error:Dynamic) {}
			return value;
		}
	}

	static function auditBlockExpression():Int {
		var value = 1;
		var ignored = if (true) {
			try {
				value = 42;
				throw "stop";
			} catch (error:Dynamic) {}
			0;
		} else 0;
		return value;
	}

	static function run():Int {
		if (auditAfterCatch() != 42)
			return 1;
		if (auditBeforeStore() != 42)
			return 2;
		if (auditShadow() != 42)
			return 3;
		if (auditPostfix() != 42)
			return 4;
		if (auditUninitialized() != 42)
			return 5;
		var closure = () -> {
			var value = 1;
			try {
				if (value == 1) {
					value = 42;
					throw "stop";
				}
			} catch (error:Dynamic) {}
			return value;
		};
		if (closure() != 42)
			return 6;
		var a = [10, 20, 30];
		var index = 0;
		a[index++] += 1;
		if (a[0] + index != 12)
			return 7;
		a[index++] -= 1;
		if (a[1] != 19 || index != 2)
			return 8;
		var position = 0;
		if ("abc".substring(position++, position++).length != 1)
			return 9;
		if ("abc".substring(true ? 0 : 1, 2).length != 2)
			return 10;
		if ("abc".substring(1, true ? 3 : 2).length != 2)
			return 11;
		if ("abc".charAt(true ? 0 : 1) != "a")
			return 12;
		if ("abc".indexOf(true ? "b" : "c") != 1)
			return 13;
		var values = [42];
		if (values[true ? 0 : 0]++ != 42)
			return 14;
		var base:AuditBase = new AuditChild();
		base = new AuditBase();
		auditMake();
		var convert:(Int) -> Int = auditDynamic;
		if (convert(1) != 42)
			return 15;
		var captured = 42;
		var read = () -> {
			return captured;
		};
		if (true) {
			var captured = 1;
			captured++;
		}
		if (captured != 42 || read() != 42)
			return 16;
		if (auditLoopCell() != 42)
			return 17;
		if (auditCatchCell() != 42)
			return 18;
		if (auditBlockExpression() != 42)
			return 19;
		if (auditRepresentative(Text) != DynamicValue)
			return 20;
		return 42;
	}

	public static function main():Void {
		Sys.exit(run());
	}
}
