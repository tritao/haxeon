package abstractstatics;

/** An abstract whose statics another module reads and writes through it, imported and by its full path. */
abstract Units(Int) from Int to Int {
	public static var scale:Int = 3;
	public static final names:Array<String> = ["unit"];

	public function scaled():Int
		return this * scale;
}
