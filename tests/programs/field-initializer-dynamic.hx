class Holder {
	final placeholder:Dynamic = {};

	public var count:Int = 3;

	public static var shared:Dynamic = {};

	public function new() {}

	public function has():Bool
		return placeholder != null && shared != null;
}

function main():Int
	return new Holder().has() && new Holder().count == 3 ? 42 : 1;
