package workspace.model;

class SearchResult {
	public final document:Document;
	public final score:Int;

	public function new(document:Document, score:Int):Void {
		this.document = document;
		this.score = score;
	}
}
