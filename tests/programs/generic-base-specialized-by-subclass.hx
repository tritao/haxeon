import genericbase.User;

// A generic base class specialized by what a subclass extends, whose inherited method is called from a module edits do not
// touch: a warm build keeps the specialization a fresh build makes.
function main():Int
	return User.count() == 2 ? 42 : 1;
