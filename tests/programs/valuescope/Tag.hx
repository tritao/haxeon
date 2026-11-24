package valuescope;

// Values named like the types a module of this package uses: they are in scope only where this abstract is imported, in its
// own module, or where a Tag is expected, never in the rest of the package.
enum abstract Tag(Int) to Int {
	var Type = 13;
	var Array = 12;
	var Plain = 1;
}
