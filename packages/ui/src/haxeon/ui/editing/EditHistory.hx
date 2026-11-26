package haxeon.ui.editing;

import Observable;

/** Reversible editor history with transactions and drag/coalescing hooks. */
class EditHistory implements Observable {
	final undoStack:Array<EditOperation>;
	final redoStack:Array<EditOperation>;
	var activeTransaction:Null<EditTransaction>;
	var nextStateToken:Int;
	var nextPersistentToken:Int = 1;

	/**
	 * Identifies the saved-content state: it changes only with edits that affect persistence, and undoing back gives
	 * the earlier token again.
	 */
	public var persistentStateToken(default, null):Int = 0;
	var coalescingAllowed:Bool = true;

	/** The most undo entries kept, or zero for no limit. */
	public final maxOperations:Int;

	/** The most memory, estimated, the entries may retain, or zero for no limit. The oldest entries go first. */
	public final maxEstimatedBytes:Int;

	/** The memory the entries retain, estimated from their operations. */
	public var estimatedRetainedBytes(default, null):Int;

	/** Identifies the current state; undoing back to a state gives its token again. */
	public var stateToken(default, null):Int;

	/** Counts changes to the history, so views of it rebuild. */
	public var revision(default, null):Int;

	/** A zero limit means unlimited. Project documents opt into explicit limits. */
	public function new(?maxOperations:Int = 0, ?maxEstimatedBytes:Int = 0) {
		if (maxOperations < 0 || maxEstimatedBytes < 0)
			throw "Edit history limits cannot be negative";
		undoStack = [];
		redoStack = [];
		activeTransaction = null;
		this.maxOperations = maxOperations;
		this.maxEstimatedBytes = maxEstimatedBytes;
		estimatedRetainedBytes = 0;
		nextStateToken = 1;
		stateToken = 0;
		revision = 0;
	}

	/** Whether there is an entry to undo. */
	public var canUndo(get, never):Bool;
	inline function get_canUndo():Bool {
		var currentRevision = revision;
		return undoStack.length > 0;
	}

	/** Whether there is an entry to redo. */
	public var canRedo(get, never):Bool;
	inline function get_canRedo():Bool {
		var currentRevision = revision;
		return redoStack.length > 0;
	}

	/** How many entries can be undone. */
	public var undoCount(get, never):Int;
	inline function get_undoCount():Int
		return undoStack.length;

	/** How many entries can be redone. */
	public var redoCount(get, never):Int;
	inline function get_redoCount():Int
		return redoStack.length;

	/** The label of the entry `undo` would undo, or null. */
	public function undoLabel():Null<String>
		return undoStack.length == 0 ? null : undoStack[undoStack.length - 1].label;

	/** The label of the entry `redo` would redo, or null. */
	public function redoLabel():Null<String>
		return redoStack.length == 0 ? null : redoStack[redoStack.length - 1].label;

	/** Applies an operation and adds it to the undo stack. */
	public function apply(operation:EditOperation, ?coalesceKey:String):Bool {
		ensureNoActiveTransaction();
		if (operation == null)
			throw "Edit history cannot apply null operations";
		if (exceedsSingleOperationBudget(operation))
			return false;
		operation.apply();
		pushApplied(operation, coalesceKey == null ? operation.coalesceKey : coalesceKey);
		return true;
	}

	/** Adds an operation that the caller has already applied. */
	public function record(operation:EditOperation, ?coalesceKey:String):Bool {
		ensureNoActiveTransaction();
		if (operation == null)
			throw "Edit history cannot record null operations";
		if (exceedsSingleOperationBudget(operation)) {
			// record() follows a caller mutation, so roll it back when it cannot be retained.
			operation.undo();
			return false;
		}
		pushApplied(operation, coalesceKey == null ? operation.coalesceKey : coalesceKey);
		return true;
	}

	/** Begins a transaction for a compound edit or a continuous drag. */
	public function begin(label:String, ?coalesceKey:String):EditTransaction {
		if (label == null || label.length == 0)
			throw "Edit transactions require a label";
		if (coalesceKey != null && coalesceKey.length == 0)
			throw "Edit transaction coalescing keys cannot be empty";
		if (activeTransaction != null)
			throw "Edit history does not support nested transactions";
		var result = new EditTransaction(this, label, coalesceKey);
		activeTransaction = result;
		return result;
	}

	/** Preserve this history state as an independently undoable boundary. */
	public function breakCoalescing():Void coalescingAllowed = false;

	/** Undoes the latest entry. Returns false when there is none. */
	public function undo():Bool {
		breakCoalescing();
		ensureNoActiveTransaction();
		if (undoStack.length == 0)
			return false;
		var operation = undoStack[undoStack.length - 1];
		operation.undo();
		undoStack.pop();
		redoStack.push(operation);
		stateToken = operation.beforeStateToken;
		persistentStateToken = operation.beforePersistentToken;
		revision++;
		return true;
	}

	/** Redoes the latest undone entry. Returns false when there is none. */
	public function redo():Bool {
		breakCoalescing();
		ensureNoActiveTransaction();
		if (redoStack.length == 0)
			return false;
		var operation = redoStack[redoStack.length - 1];
		operation.apply();
		redoStack.pop();
		undoStack.push(operation);
		stateToken = operation.afterStateToken;
		persistentStateToken = operation.afterPersistentToken;
		revision++;
		return true;
	}

	/** Drops every entry. Throws while a transaction is open. */
	public function clear():Void {
		ensureNoActiveTransaction();
		undoStack.resize(0);
		redoStack.resize(0);
		estimatedRetainedBytes = 0;
		revision++;
	}

	@:allow(haxeon.ui.editing.EditTransaction)
	function commitTransaction(transaction:EditTransaction):Bool {
		if (activeTransaction != transaction)
			throw "Edit transaction does not belong to this history";
		activeTransaction = null;
		var operations = transaction.operationList();
		if (operations.length == 0)
			return false;
		var estimatedBytes = 64;
		for (operation in operations)
			estimatedBytes = saturatedAdd(estimatedBytes, operation.estimatedRetainedBytes);
		if (maxEstimatedBytes > 0 && estimatedBytes > maxEstimatedBytes) {
			var rollbackIndex = operations.length - 1;
			while (rollbackIndex >= 0) {
				operations[rollbackIndex].undo();
				rollbackIndex--;
			}
			revision++;
			return false;
		}
		var affectsPersistence = false;
		for (operation in operations) if (operation.affectsPersistence) affectsPersistence = true;
		var composite = new EditOperation(transaction.label,
			function() {
				for (operation in operations)
					operation.apply();
			}, function() {
			var index = operations.length - 1;
			while (index >= 0) {
				operations[index].undo();
				index--;
			}
		}, transaction.coalesceKey, function(next) {
			if (next == null || next.transactionOperations == null)
				return false;
			for (operation in next.transactionOperations)
				operations.push(operation);
			return true;
		}, operations, estimatedBytes, affectsPersistence);
		composite.transactionOperations = operations;
		pushApplied(composite, composite.coalesceKey);
		return true;
	}

	@:allow(haxeon.ui.editing.EditTransaction)
	function cancelTransaction(transaction:EditTransaction):Bool {
		if (activeTransaction != transaction)
			throw "Edit transaction does not belong to this history";
		activeTransaction = null;
		var operations = transaction.operationList();
		var index = operations.length - 1;
		while (index >= 0) {
			operations[index].undo();
			index--;
		}
		if (operations.length > 0)
			revision++;
		return operations.length > 0;
	}

	function pushApplied(operation:EditOperation, coalesceKey:Null<String>):Void {
		if (coalescingAllowed && coalesceKey != null && undoStack.length > 0) {
			var previous = undoStack[undoStack.length - 1];
			if (previous.coalesceKey == coalesceKey && previous.affectsPersistence == operation.affectsPersistence) {
				var previousBytes = previous.estimatedRetainedBytes;
				var transactionMergeOverBudget = maxEstimatedBytes > 0 && previous.transactionOperations != null
					&& operation.transactionOperations != null
					&& saturatedAdd(previousBytes, operation.estimatedRetainedBytes) > maxEstimatedBytes;
				if (!transactionMergeOverBudget && previous.mergeFrom(operation)) {
					var mergedBytes = previous.transactionOperations != null && operation.transactionOperations != null
						? saturatedAdd(previousBytes, operation.estimatedRetainedBytes)
						: (previousBytes > operation.estimatedRetainedBytes
						? previousBytes : operation.estimatedRetainedBytes);
					previous.setEstimatedRetainedBytes(mergedBytes);
					estimatedRetainedBytes = saturatedAdd(estimatedRetainedBytes - previousBytes, mergedBytes);
					previous.afterStateToken = nextStateToken++;
					previous.afterPersistentToken = previous.affectsPersistence
						? nextPersistentToken++ : persistentStateToken;
					persistentStateToken = previous.afterPersistentToken;
					stateToken = previous.afterStateToken;
					clearRedoStack();
					revision++;
					trimToBudget();
					return;
				}
			}
		}
		coalescingAllowed = true;
		operation.beforePersistentToken = persistentStateToken;
		operation.afterPersistentToken = operation.affectsPersistence ? nextPersistentToken++ : persistentStateToken;
		operation.beforeStateToken = stateToken;
		operation.afterStateToken = nextStateToken++;
		stateToken = operation.afterStateToken;
		persistentStateToken = operation.afterPersistentToken;
		undoStack.push(operation);
		estimatedRetainedBytes = saturatedAdd(estimatedRetainedBytes, operation.estimatedRetainedBytes);
		clearRedoStack();
		revision++;
		trimToBudget();
	}

	function exceedsSingleOperationBudget(operation:EditOperation):Bool
		return maxEstimatedBytes > 0 && operation.estimatedRetainedBytes > maxEstimatedBytes;

	function clearRedoStack():Void {
		for (operation in redoStack)
			estimatedRetainedBytes -= operation.estimatedRetainedBytes;
		redoStack.resize(0);
	}

	function trimToBudget():Void {
		var removeCount = 0;
		var remainingBytes = estimatedRetainedBytes;
		var remainingOperations = undoStack.length + redoStack.length;
		while (removeCount < undoStack.length - 1 && ((maxOperations > 0 && remainingOperations > maxOperations)
			|| (maxEstimatedBytes > 0 && remainingBytes > maxEstimatedBytes))) {
			remainingBytes -= undoStack[removeCount].estimatedRetainedBytes;
			remainingOperations--;
			removeCount++;
		}
		if (removeCount == 0) return;
		for (index in 0...removeCount)
			estimatedRetainedBytes -= undoStack[index].estimatedRetainedBytes;
		undoStack.splice(0, removeCount);
	}

	static function saturatedAdd(lhs:Int, rhs:Int):Int {
		var sum = lhs + rhs;
		return sum < lhs ? 0x7fffffff : sum;
	}

	function ensureNoActiveTransaction():Void {
		if (activeTransaction != null)
			throw "Edit history has an open transaction";
	}
}

/** One reversible application mutation owned by EditHistory. */
class EditOperation {
	/** What the edit is called in menus, as in "Undo Move". */
	public final label:String;
	/** Session operations remain undoable without changing the document savepoint. */
	public final affectsPersistence:Bool;
	@:allow(haxeon.ui.editing.EditHistory) var beforePersistentToken:Int;
	@:allow(haxeon.ui.editing.EditHistory) var afterPersistentToken:Int;
	/** Merges this operation into the previous one when both have the same key, so a run of edits undoes as one step. */
	public final coalesceKey:Null<String>;
	/** Approximate bytes retained by this operation and its captured undo data. */
	public var estimatedRetainedBytes(default, null):Int;
	/** Optional caller-owned value used by a coalescing callback. */
	public final mergeData:Dynamic;
	var applyAction:Void->Void;
	var undoAction:Void->Void;
	final mergeAction:Null<EditOperation->Bool>;
	@:allow(haxeon.ui.editing.EditHistory)
	var transactionOperations:Null<Array<EditOperation>>;
	@:allow(haxeon.ui.editing.EditHistory)
	var beforeStateToken:Int;
	@:allow(haxeon.ui.editing.EditHistory)
	var afterStateToken:Int;

	/**
	 * An operation `label` that `apply` performs and `undo` reverses; `merge` may fold a later operation with the same
	 * `coalesceKey` into this one.
	 */
	public function new(label:String, apply:Void->Void, undo:Void->Void,
			?coalesceKey:String, ?merge:EditOperation->Bool, ?mergeData:Dynamic,
			?estimatedRetainedBytes:Int = 256, affectsPersistence:Bool = true) {
		if (label == null || label.length == 0 || apply == null || undo == null)
			throw "Edit operations require a label, apply action, and undo action";
		if (coalesceKey != null && coalesceKey.length == 0)
			throw "Edit coalescing keys cannot be empty";
		this.label = label;
		this.affectsPersistence = affectsPersistence;
		this.applyAction = apply;
		this.undoAction = undo;
		this.coalesceKey = coalesceKey;
		this.mergeAction = merge;
		this.mergeData = mergeData;
		if (estimatedRetainedBytes < 0)
			throw "Edit operation retained-byte estimates cannot be negative";
		this.estimatedRetainedBytes = estimatedRetainedBytes;
		transactionOperations = null;
		beforeStateToken = -1;
		afterStateToken = -1;
	}

	/** Performs the edit. */
	public function apply():Void
		applyAction();

	/** Reverses it. */
	public function undo():Void
		undoAction();

	/**
	 * Replaces the actions retained by this operation after a successful merge.
	 * The merge callback can use this to keep the original undo point while
	 * extending the operation's final state.
	 */
	public function replaceActions(apply:Void->Void, undo:Void->Void):Void {
		if (apply == null || undo == null)
			throw "Merged edit actions cannot be null";
		applyAction = apply;
		undoAction = undo;
	}

	@:allow(haxeon.ui.editing.EditHistory)
	function setEstimatedRetainedBytes(bytes:Int):Void {
		if (bytes < 0) throw "Edit operation retained-byte estimates cannot be negative";
		estimatedRetainedBytes = bytes;
	}

	@:allow(haxeon.ui.editing.EditHistory)
	function mergeFrom(next:EditOperation):Bool {
		return mergeAction != null && next != null && mergeAction(next);
	}
}

/** Collects several already-applied edits into one undoable history entry. */
class EditTransaction {
	final history:EditHistory;

	/** What the compound edit is called in menus. */
	public final label:String;

	/** Merges the committed entry into the previous one with the same key. */
	public final coalesceKey:Null<String>;
	final operations:Array<EditOperation>;
	var closed:Bool;

	@:allow(haxeon.ui.editing.EditHistory)
	private function new(history:EditHistory, label:String, coalesceKey:Null<String>) {
		this.history = history;
		this.label = label;
		this.coalesceKey = coalesceKey;
		operations = [];
		closed = false;
	}

	/** Applies and records an operation in this transaction. */
	public function apply(operation:EditOperation):Bool {
		ensureOpen();
		if (operation == null)
			throw "Edit transactions cannot apply null operations";
		operation.apply();
		operations.push(operation);
		return true;
	}

	/** Records a mutation that the caller has already applied. */
	public function record(operation:EditOperation):Bool {
		ensureOpen();
		if (operation == null)
			throw "Edit transactions cannot record null operations";
		operations.push(operation);
		return true;
	}

	/** Commits the collected mutations as one history entry. */
	public function commit():Bool {
		ensureOpen();
		closed = true;
		return history.commitTransaction(this);
	}

	/** Undoes all mutations and discards the transaction. */
	public function cancel():Bool {
		ensureOpen();
		closed = true;
		return history.cancelTransaction(this);
	}

	@:allow(haxeon.ui.editing.EditHistory)
	function operationList():Array<EditOperation>
		return operations.copy();

	function ensureOpen():Void {
		if (closed)
			throw "Edit transaction is already closed";
	}
}
