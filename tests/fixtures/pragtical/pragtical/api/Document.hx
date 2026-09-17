package pragtical.api;

class Document {
	public final name:String;
	public final text:String;
	public var selection:Int;

	public function new(name:String, selection:Int, ?text:String):Void {
		this.name = name;
		this.selection = selection;
		this.text = text == null ? "" : text;
	}
}
