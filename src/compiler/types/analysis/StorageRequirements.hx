package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstType;

/**
 * The locals of a function or lambda that need a cell, and those a closure can write, by declaration key, read from the
 * body's resolution. A local needs a cell when a lambda captures it and it is written somewhere (a field of a value local
 * counts), when a local function refers to itself, or when it is written inside a `try` it was declared outside of, so the
 * value survives the exception edge. Only the locals the function or lambda declares itself are its own: a nested lambda's
 * are decided when it is typed.
 */
class StorageRequirements {
	public final mutableCaptures:Map<String, Bool> = [];
	public final exceptionCells:Map<String, Bool> = [];
	public final closureWrites:Map<String, Bool> = [];

	final resolution:BodyResolution;
	final mayHoldValue:Null<(Null<AstType>, Null<AstExpression>) -> Bool>;
	final mayBeKeyPath:Null<(Null<AstType>, Null<AstExpression>) -> Bool>;

	/** Whether each declaration asked about may hold a value type, by id. */
	final values:Map<Int, Bool> = [];

	final firstDeclaration:Int;

	function new(resolution:BodyResolution, firstDeclaration:Int,
			mayHoldValue:Null<(Null<AstType>, Null<AstExpression>) -> Bool>,
			mayBeKeyPath:Null<(Null<AstType>, Null<AstExpression>) -> Bool>) {
		this.resolution = resolution;
		this.firstDeclaration = firstDeclaration;
		this.mayHoldValue = mayHoldValue;
		this.mayBeKeyPath = mayBeKeyPath;
	}

	/** The requirements of the whole body of `resolution`. */
	public static function ofBody(resolution:BodyResolution,
			mayHoldValue:Null<(Null<AstType>, Null<AstExpression>) -> Bool>,
			mayBeKeyPath:Null<(Null<AstType>, Null<AstExpression>) -> Bool>):StorageRequirements {
		var result = new StorageRequirements(resolution, 0, mayHoldValue, mayBeKeyPath);
		result.collect(0, resolution.length, resolution.declarationKeys.length, 0);
		return result;
	}

	/** The requirements of the lambda at `position` in `resolution`, or null when it has no such lambda. */
	public static function ofLambda(resolution:BodyResolution, position:Int,
			mayHoldValue:Null<(Null<AstType>, Null<AstExpression>) -> Bool>,
			mayBeKeyPath:Null<(Null<AstType>, Null<AstExpression>) -> Bool>):Null<StorageRequirements> {
		var lambda = resolution.lambdaAt(position);
		if (lambda == null)
			return null;
		var result = new StorageRequirements(resolution, lambda.firstDeclaration, mayHoldValue, mayBeKeyPath);
		result.collect(lambda.first, lambda.end, lambda.endDeclaration, lambda.depth);
		return result;
	}

	/** Reads references `[first, end)` for the declarations from `firstDeclaration` to `endDeclaration` at lambda `depth`. */
	function collect(first:Int, end:Int, endDeclaration:Int, depth:Int):Void {
		var written:Map<Int, Bool> = [];
		inline function own(declaration:Int):Bool
			return declaration >= firstDeclaration && declaration < endDeclaration
				&& resolution.declarationLambdaDepths[declaration] == depth;
		for (index in first...end) {
			var declaration = resolution.declarations[index];
			if (own(declaration) && writes(index, declaration))
				written.set(declaration, true);
		}
		for (index in first...end) {
			var declaration = resolution.declarations[index];
			if (!own(declaration))
				continue;
			var key = resolution.declarationKeys[declaration],
				captured = resolution.hasFlag(index, BodyResolution.CAPTURED);
			switch resolution.referenceAt(index) {
				case Write if (resolution.names[index].indexOf(".") < 0):
					if (captured) {
						mutableCaptures.set(key, true);
						closureWrites.set(key, true);
					}
					if (resolution.hasFlag(index, BodyResolution.DEEPER_TRY))
						exceptionCells.set(key, true);
				case Use, Callee, Receiver, MemberCall:
					if (refersToItself(index, declaration) || captured && written.exists(declaration))
						mutableCaptures.set(key, true);
					// `local.method()` may write a value local through its receiver.
					if (resolution.referenceAt(index) == MemberCall && captured && isValue(declaration)) {
						mutableCaptures.set(key, true);
						closureWrites.set(key, true);
					}
				default:
					if (captured && writes(index, declaration)) {
						mutableCaptures.set(key, true);
						closureWrites.set(key, true);
					}
			}
		}
	}

	/** Whether reference `index` writes `declaration` or a field of it. */
	function writes(index:Int, declaration:Int):Bool
		return switch resolution.referenceAt(index) {
			case Write: resolution.names[index].indexOf(".") < 0 || isValue(declaration);
			case PlaceWrite, MemberCall: isValue(declaration);
			case PathSet: pathReceiver(index) && isValue(declaration);
			default: false;
		};

	/** A reference to a local function from its own body: the function lives in a cell that exists before the closure does. */
	function refersToItself(index:Int, declaration:Int):Bool {
		var position = resolution.localFunctionAt(declaration);
		if (position == null)
			return false;
		var lambda = resolution.lambdaAt(position);
		return lambda != null && index >= lambda.first && index < lambda.end;
	}

	/** Whether the receiver of the `set` call of `PathSet` `index` may be a key path. */
	function pathReceiver(index:Int):Bool {
		var path = resolution.pathTargetAt(index);
		if (mayBeKeyPath == null || path == null)
			return false;
		return switch path.target {
			case Variable(name, _) if (name.indexOf(".") < 0):
				path.declaration < 0
					|| mayBeKeyPath(resolution.declarationTypes[path.declaration],
					resolution.declarationInitializers[path.declaration]);
			default: mayBeKeyPath(null, path.target);
		};
	}

	function isValue(declaration:Int):Bool {
		if (mayHoldValue == null)
			return false;
		var known = values.get(declaration);
		if (known == null) {
			known = mayHoldValue(resolution.declarationTypes[declaration],
				resolution.declarationInitializers[declaration]);
			values.set(declaration, known);
		}
		return known;
	}
}
