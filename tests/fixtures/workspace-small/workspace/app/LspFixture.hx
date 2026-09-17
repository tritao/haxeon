package workspace.app;

import workspace.model.Document;

function main():Int {
	var document = new Document("notes.txt", "notes");
	return document.selection;
}
