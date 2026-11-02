enum NameValue { Entry(value:String); Other; }
class PatternBase { public static inline final INHERITED = "inherited"; }
class PatternCheck extends PatternBase {
	static inline final MATCH = "match";
	static var captured = "static";
	public static function matches(value:NameValue):Bool return switch value {
		case Entry(MATCH): true;
		default: false;
	};
	public static function binds(value:NameValue):Bool return switch value {
		case Entry(captured): captured == "bound";
		default: false;
	};
	public static function inherited(value:NameValue):Bool return switch value {
		case Entry(INHERITED): true;
		default: false;
	};
}
function main():Int {
	if (!PatternCheck.matches(Entry("match"))) return 1;
	if (PatternCheck.matches(Entry("different")) || PatternCheck.matches(Other)) return 2;
	if (!PatternCheck.binds(Entry("bound")) || PatternCheck.binds(Entry("static"))) return 3;
	if (!PatternCheck.inherited(Entry("inherited")) || PatternCheck.inherited(Entry("different"))) return 4;
	return 42;
}
