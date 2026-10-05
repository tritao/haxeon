package nativekit.ui.editing;

/** Reversible editor history with transactions and drag/coalescing hooks. */
class EditHistory {
	final undoStack:Array<EditOperation>;
	final redoStack:Array<EditOperation>;
	var activeTransaction:Null<EditTransaction>;
	var nextStateToken:Int;
	var coalescingAllowed:Bool = true;
	public final maxOperations:Int;
	public final maxEstimatedBytes:Int;
	public var estimatedRetainedBytes(default, null):Int;
	public var stateToken(default, null):Int;
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

	public var canUndo(get, never):Bool;
	inline function get_canUndo():Bool
		return undoStack.length > 0;

	public var canRedo(get, never):Bool;
	inline function get_canRedo():Bool
		return redoStack.length > 0;

	public var undoCount(get, never):Int;
	inline function get_undoCount():Int
		return undoStack.length;

	public var redoCount(get, never):Int;
	inline function get_redoCount():Int
		return redoStack.length;

	public function undoLabel():Null<String>
		return undoStack.length == 0 ? null : undoStack[undoStack.length - 1].label;

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
		revision++;
		return true;
	}

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
		revision++;
		return true;
	}

	public function clear():Void {
		ensureNoActiveTransaction();
		undoStack.resize(0);
		redoStack.resize(0);
		estimatedRetainedBytes = 0;
		revision++;
	}

	@:allow(nativekit.ui.editing.EditTransaction)
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
			}, operations, estimatedBytes);
		composite.transactionOperations = operations;
		pushApplied(composite, composite.coalesceKey);
		return true;
	}

	@:allow(nativekit.ui.editing.EditTransaction)
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
			if (previous.coalesceKey == coalesceKey) {
				var previousBytes = previous.estimatedRetainedBytes;
				var transactionMergeOverBudget = maxEstimatedBytes > 0 &&
					previous.transactionOperations != null && operation.transactionOperations != null &&
					saturatedAdd(previousBytes, operation.estimatedRetainedBytes) > maxEstimatedBytes;
				if (!transactionMergeOverBudget && previous.mergeFrom(operation)) {
					var mergedBytes = previous.transactionOperations != null && operation.transactionOperations != null
						? saturatedAdd(previousBytes, operation.estimatedRetainedBytes)
						: (previousBytes > operation.estimatedRetainedBytes
							? previousBytes : operation.estimatedRetainedBytes);
					previous.setEstimatedRetainedBytes(mergedBytes);
					estimatedRetainedBytes = saturatedAdd(estimatedRetainedBytes - previousBytes, mergedBytes);
					previous.afterStateToken = nextStateToken++;
					stateToken = previous.afterStateToken;
					clearRedoStack();
					revision++;
					trimToBudget();
					return;
				}
			}
		}
		coalescingAllowed = true;
		operation.beforeStateToken = stateToken;
		operation.afterStateToken = nextStateToken++;
		stateToken = operation.afterStateToken;
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
		while (removeCount < undoStack.length - 1 &&
			((maxOperations > 0 && remainingOperations > maxOperations) ||
			 (maxEstimatedBytes > 0 && remainingBytes > maxEstimatedBytes))) {
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
