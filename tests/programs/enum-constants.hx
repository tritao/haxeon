// Enum constructors are constants: a static field takes its type from one, an inline field holds one without arguments,
// and comparing with a static final or inline constructor needs no Equatable, as comparing with the constructor does.
enum Mode {
	Fast;
	Slow;
	Custom(rate:Int);
}

class Defaults {
	public static inline final MODE = Fast;
	public static final FALLBACK = Mode.Slow;
	public static final CUSTOM = Custom(3);
	public static final BARE = Slow;
}

function main():Int {
	var chosen = Custom(1);
	if (chosen == Defaults.MODE || chosen == Defaults.FALLBACK || Defaults.BARE != Slow)
		return 1;
	if (!(Defaults.MODE == Fast) || Defaults.FALLBACK.getIndex() != 1)
		return 2;
	var rate = switch Defaults.CUSTOM {
		case Custom(value): value;
		default: 0;
	};
	if (rate != 3)
		return 3;
	var picked:Mode = Defaults.MODE;
	return picked == Fast ? 42 : 4;
}
