package pragtical.api;

class Document {
	public final name:String;
	public var selection:Int;

	public function new(name:String, selection:Int):Void {
		this.name = name;
		this.selection = selection;
	}
}
