package pragtical.api;

import pragtical.api.Document;

class Editor {
	public var commands:Array<String>;
	public var callbacks:Map<String, Void->Int>;
	public var documents:Array<Document>;

	public function new():Void {
		this.commands = new Array<String>(0);
		this.callbacks = new Map<String, Void->Int>();
		this.documents = new Array<pragtical.api.Document>(0);
	}

	public function open(document:Document):Void {
		documents.push(document);
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
		return callback();
	}
}
