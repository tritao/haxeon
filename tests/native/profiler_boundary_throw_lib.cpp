/* A function that throws, for the exception to unwind through the boundary thunk that hooks it. */
extern "C" void thrower( int value ) {
	throw value;
}
