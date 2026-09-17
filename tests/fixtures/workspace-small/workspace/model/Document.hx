package workspace.model;

class Document {
	public final name:String;
	public final text:String;
	public var selection:Int;

	public function new(name:String, text:String):Void {
		this.name = name;
		this.text = text;
		this.selection = 0;
	}

	public function matches(query:String):Bool
		return query.length == 0 || text.indexOf(query) >= 0;
}
