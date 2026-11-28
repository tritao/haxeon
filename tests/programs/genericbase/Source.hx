package genericbase;

/** A generic base class, which `Stream` specializes by extending it. */
class Source<E> {
	public function new() {}

	public function twice(value:E):Array<E>
		return [value, value];
}

enum Failure {
	Broken;
}

/** Specializes `Source` at `Failure` through its extends clause alone. */
class Stream extends Source<Failure> {
	public function new()
		super();
}
