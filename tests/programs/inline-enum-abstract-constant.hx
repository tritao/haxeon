enum abstract Mode(Int) to Int {
	var Active = 42;
	var Inactive = 7;
}

enum abstract Label(String) {
	var Ready = "ready";
}

abstract Wrapped<T>(T) from T to T {}

class Constants {
	public static inline var ACTIVE:Mode = Mode.Active;
	public static inline var ALIAS:Mode = ACTIVE;
	public static inline var INFERRED = Mode.Active;
	public static inline var SELECTED:Mode = true ? Mode.Active : Mode.Inactive;
	public static inline var LABEL:Label = Label.Ready;
	public static inline var OPTIONAL:Null<Mode> = Mode.Active;
	public static inline var MISSING:Null<Mode> = null;
	public static inline var OPTIONAL_LABEL:Null<Label> = Label.Ready;
	public static inline var WRAPPED:Wrapped<Int> = 42;
}

function read(mode:Mode = Constants.ALIAS):Int
	return mode;

function main():Int {
	if (Constants.ACTIVE != Mode.Active || Constants.ALIAS != Mode.Active || Constants.LABEL != Label.Ready || Constants.INFERRED != Mode.Active
		|| Constants.SELECTED != Mode.Active)
		return 1;
	if (Constants.OPTIONAL != Mode.Active || Constants.MISSING != null || Constants.OPTIONAL_LABEL != Label.Ready)
		return 2;
	if (Constants.WRAPPED != 42 || read() != 42)
		return 3;
	return switch (Mode.Active) {
		case Constants.ALIAS: 42;
		default: 4;
	};
}
