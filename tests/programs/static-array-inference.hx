class Constants {
	public static inline final READ = "read";
	public static inline final EVENTS = "events";
}

class Consumer {
	public static final names = [Constants.READ, Constants.EVENTS];
	public static final nested = [[Constants.READ], [Constants.EVENTS]];
}

function main():Int {
	return Consumer.names[0] == "read" && Consumer.nested[1][0] == "events" ? 42 : 1;
}
