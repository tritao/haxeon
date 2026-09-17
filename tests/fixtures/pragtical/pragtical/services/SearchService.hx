package pragtical.services;

import pragtical.api.Document;

/**
 * Small host-owned utility service used by the first migrated Pragtical
 * plugin. The service deliberately keeps its document collection separate
 * from command registration so both pieces can survive a plugin reload.
 */
class SearchService {
	public final documents:Array<Document>;
	final byName:Map<String, Document>;
	public var lastQuery:String;

	public function new():Void {
		this.documents = new Array<Document>(0);
		this.byName = new Map<String, Document>();
		this.lastQuery = "";
	}

	public function add(document:Document):Void {
		if (!byName.exists(document.name))
			documents.push(document);
		byName[document.name] = document;
	}

	public function remove(name:String):Void {
		var document = byName[name];
		if (document == null)
			return;

		byName.remove(name);
		for (index in 0...documents.length)
			if (documents[index] == document) {
				documents.splice(index, 1);
				break;
			}
	}

	public function find(query:String):Int {
		lastQuery = query;
		var matches = 0;
		for (document in documents) {
			var offset = document.text.indexOf(query);
			if (query.length == 0 || offset >= 0) {
				document.selection = offset < 0 ? 0 : offset;
				matches++;
			}
		}
		return matches;
	}

	public function count():Int
		return documents.length;
}
