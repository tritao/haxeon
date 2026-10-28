package compiler.hl.patch;

import compiler.hl.HlCode.HlTypeDef;

/**
 * A field a patch gives an existing class in one of its reserved slots (HLP section 7): the class's type, the slot's index
 * among the class's own fields, and the field's name (a string index) and type.
 */
typedef HlAddedField = {
	final type:Int;
	final field:Int;
	final name:Int;
	final fieldType:Int;
}

/**
 * A class whose instances made before the patch run its live initializer (HLP section 8): the class's type and the
 * initializer's function slot, which the patch names by stable ID.
 */
typedef HlMigration = {
	final type:Int;
	final slot:Int;
}

/**
 * How a patch changes the layout of objects the running module has (see `HlModuleAssembler.planObjects`): the fields it
 * gives them, the definitions the running module has for the types those fields rewrite (the patch's type prefix hash
 * covers those, not the rewritten ones), and the migrations, bases first.
 */
typedef HlObjectLayout = {
	final fields:Array<HlAddedField>;
	final previousTypes:Map<Int, HlTypeDef>;
	final migrations:Array<HlMigration>;
}
