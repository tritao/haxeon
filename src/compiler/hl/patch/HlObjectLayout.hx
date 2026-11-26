package compiler.hl.patch;

/**
 * A class whose instances made before the patch run its live initializer: the class's type, which orders the migrations bases
 * first, and the class and its initializer by name, which a patch of sections names them by.
 */
typedef HlMigration = {
	final type:Int;
	final className:String;
	final initializer:String;
}

/**
 * How a patch changes the layout of objects the running module has (see `HlModuleAssembler.planObjects`): the fields it gives
 * them in reserved slots, as `Class.field`, and the migrations, bases first.
 */
typedef HlObjectLayout = {
	final fields:Array<String>;
	final migrations:Array<HlMigration>;
}
