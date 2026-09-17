package workspace.services;

import workspace.model.Document;
import workspace.model.SearchResult;

class SearchService {
	public final documents:Array<Document>;
	public final latest:Map<String, SearchResult>;

	public function new():Void {
		this.documents = new Array<Document>(0);
		this.latest = new Map<String, SearchResult>();
	}

	public function add(document:Document):Void {
		documents.push(document);
	}

	public function find(query:String):Int {
		var matches = 0;
		for (document in documents)
			if (document.matches(query)) {
				document.selection = query.length;
				latest[document.name] = new SearchResult(document, query.length);
				matches++;
			}
		return matches;
	}
}
