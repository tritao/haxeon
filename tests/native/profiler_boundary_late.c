long late_only( long );

/* The only caller of late_only, in an object loaded with dlopen after the boundary hooks are installed. */
long late_call( long x ) {
	return late_only(x) * 2;
}
