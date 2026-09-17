package workspace.api;

import workspace.model.Document;
import workspace.services.SearchService;

class Editor {
	public final search:SearchService;
	public final documents:Array<Document>;
	public final callbacks:Map<String, Void->Int>;

	public function new():Void {
		this.search = new SearchService();
		this.documents = new Array<Document>(0);
		this.callbacks = new Map<String, Void->Int>();
	}

	public function open(document:Document):Void {
		documents.push(document);
		search.add(document);
	}

	public function register(name:String, callback:Void->Int):Void {
		callbacks[name] = callback;
	}

	public function execute(name:String):Int {
		var callback = callbacks[name];
		return callback == null ? 0 : callback();
	}
}
