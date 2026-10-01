package samepackage;

abstract Image(Int) {
	public inline function new(value:Int)
		this = value;

	public inline function raw():Int
		return cast this;
}
