package pragtical.app;

import pragtical.api.Document;

function main():Int {
	var document = new Document("notes.txt", 4);
	return document.selection;
}
