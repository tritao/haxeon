package haxeon.ui.style;

import Equatable;

/**
 * What a widget's style rules select on: its type, key, ID, classes and tags. A widget gives it once, to
 * `BuildContext.styled`, which resolves the style from it and records it on the node.
 */
struct StyleIdentity implements Equatable {
	/** The widget type, such as "button". */
	public final type:String;

	/** The widget's key. */
	public final key:Null<String>;

	/** The widget's style ID. */
	public final id:Null<String>;

	/** Its classes; nobody changes them after this. */
	public final classes:Array<String>;

	/** Its tags; nobody changes them after this. */
	public final tags:Array<String>;

	/** An identity of `type`, which must not be empty. */
	public function new(type:String, ?key:String, ?id:String, ?classes:Array<String>, ?tags:Array<String>) {
		if (type == null || type.length == 0) throw "A style identity requires a type";
		this.type = type;
		this.key = key;
		this.id = id;
		this.classes = StyleTarget.shared(classes);
		this.tags = StyleTarget.shared(tags);
	}
}
