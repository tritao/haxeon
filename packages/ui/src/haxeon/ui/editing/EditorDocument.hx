package haxeon.ui.editing;

import Observable;

import haxeon.ui.editing.EditHistory;
/** Document-owned history and savepoint state for editor applications. */
class EditorDocument implements Observable {
	/** A stable identifier for the document. */
	public final id:String;

	/** Its undo history. */
	public final history:EditHistory;
	var savedStateToken:Int;
	var externallyDirty:Bool;

	/** A clean document `id`, with `history` or a new unlimited one. Throws when `id` is empty. */
	public function new(id:String, ?history:EditHistory) {
		if (id == null || id.length == 0)
			throw "Editor documents require a stable ID";
		this.id = id;
		this.history = history == null ? new EditHistory() : history;
		savedStateToken = this.history.persistentStateToken;
		externallyDirty = false;
	}

	/** The history's revision. */
	public var revision(get, never):Int;
	inline function get_revision():Int
		return history.revision;

	/** Whether it has changes since it was last saved. */
	public var isDirty(get, never):Bool;
	inline function get_isDirty():Bool
		return externallyDirty || history.persistentStateToken != savedStateToken;

	/** Whether there is an edit to undo. */
	public var canUndo(get, never):Bool;
	inline function get_canUndo():Bool
		return history.canUndo;

	/** Whether there is an edit to redo. */
	public var canRedo(get, never):Bool;
	inline function get_canRedo():Bool
		return history.canRedo;

	/** Applies `operation` and records it in the history. */
	public function apply(operation:EditOperation, ?coalesceKey:String):Bool
		return history.apply(operation, coalesceKey);

	/** Records an `operation` the caller has already applied. */
	public function record(operation:EditOperation, ?coalesceKey:String):Bool
		return history.record(operation, coalesceKey);

	/** Opens a transaction collecting several edits into one entry. */
	public function begin(label:String, ?coalesceKey:String):EditTransaction
		return history.begin(label, coalesceKey);

	/** Undoes the latest edit. */
	public function undo():Bool
		return history.undo();

	/** Redoes the latest undone edit. */
	public function redo():Bool
		return history.redo();

	/** Declares that an external model mutation must be included in the next save. */
	public function markExternallyDirty():Void
		externallyDirty = true;

	/** Marks the current document state as persisted. */
	public function markSaved():Void {
		history.breakCoalescing();
		savedStateToken = history.persistentStateToken;
		externallyDirty = false;
	}

	/** Drops the history; the document stays as dirty as it was. */
	public function clearHistory():Void
		history.clear();
}
