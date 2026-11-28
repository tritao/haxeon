package genericbase;

import genericbase.Source.Failure;
import genericbase.Source.Stream;

/** Calls the inherited method from a module the program's edits leave alone. */
class User {
	public static function count():Int
		return new Stream().twice(Broken).length;
}
