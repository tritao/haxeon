package pragtical.api;

import pragtical.api.Document;
import pragtical.services.SearchService;

class Editor {
	public var commands:Array<String>;
	public var callbacks:Map<String, Void->Int>;
	public var documents:Array<Document>;
	public var search:SearchService;
	public var diagnostics:Array<String>;

	public function new():Void {
		this.commands = new Array<String>(0);
		this.callbacks = new Map<String, Void->Int>();
		this.documents = new Array<pragtical.api.Document>(0);
		this.search = new SearchService();
		this.diagnostics = new Array<String>(0);
	}

	public function open(document:Document):Void {
		documents.push(document);
		search.add(document);
	}

	public function close(name:String):Void {
		for (index in 0...documents.length)
			if (documents[index].name == name) {
				documents.splice(index, 1);
				break;
			}
		search.remove(name);
	}

	public function report(message:String):Void {
		diagnostics.push(message);
	}

	public function clearDiagnostics():Void {
		diagnostics = new Array<String>(0);
	}

	public function register(name:String, callback:Void->Int):Void {
		commands.push(name);
		callbacks[name] = callback;
	}

	public function unregister(name:String):Void {
		callbacks.remove(name);
		commands.pop();
	}

	public function execute(name:String):Int {
		var callback = callbacks[name];
		if (callback == null)
			return 0;
		return callback();
	}
}
