package haxeon.ui.properties;

/** Optional recursive structure for custom list controls. Domain validation stays
 * application-owned. Vectors have fixed components; lists own item actions. */
enum PropertyStructure {
	Value(type:PropertyType);
	Vector(components:Int);
	List(items:Null<PropertyStructure>, minimumLength:Null<Int>, maximumLength:Null<Int>, itemLabel:String);
}
