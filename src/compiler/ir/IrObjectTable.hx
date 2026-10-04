package compiler.ir;

import compiler.ir.Ir;

/**
 * The objects of a program as the inliner and its passes look them up, by name, and the direct subclasses of each.
 *
 * While `consulted` is set, every name looked up is recorded in it. A function's inlined form depends on the objects its
 * inlining consulted and on nothing else about them, so a cached form stays valid exactly while those objects are unchanged;
 * recording what was consulted is what lets one new class leave every function that never looked at it alone.
 */
class IrObjectTable {
	final objects:Map<String, IrObject>;
	final children:Map<String, Array<String>>;

	/** Where the names looked up are recorded, or null to record nothing. */
	public var consulted:Null<Map<String, Bool>> = null;

	public function new(objects:Map<String, IrObject>, children:Map<String, Array<String>>) {
		this.objects = objects;
		this.children = children;
	}

	/** A table over `objects` alone, for a pass tried by itself; no object has subclasses. */
	public static function of(objects:Map<String, IrObject>):IrObjectTable
		return new IrObjectTable(objects, []);

	public function get(name:String):Null<IrObject> {
		if (consulted != null)
			consulted.set(name, true);
		return objects.get(name);
	}

	/** The classes that extend `name` directly; what the answer is depends on `name`, so asking records it. */
	public function subclassesOf(name:String):Null<Array<String>> {
		if (consulted != null)
			consulted.set(name, true);
		return children.get(name);
	}
}
