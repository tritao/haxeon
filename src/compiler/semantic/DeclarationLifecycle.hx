package compiler.semantic;

import compiler.core.InternalError;
import compiler.types.DeclarationIndex;
import compiler.types.DeclarationIndex.DeclarationId;

/** Ordered readiness of a declaration within one candidate semantic snapshot. */
enum abstract DeclarationStage(Int) from Int to Int {
	var Declared = 0;
	var ShapeConnected = 1;
	var SignatureTyped = 2;
	var BodyTyped = 3;
	var Finalized = 4;
}

/** Candidate-local declaration state machine. */
class DeclarationLifecycle {
	/** The identities and their stages side by side, so advancing all of them walks arrays rather than a map's iterator. */
	final ids:Array<String>;

	final current:Array<DeclarationStage>;
	final positions:Map<String, Int>;

	/** The declarations of `declarations`, each at `initial`; or, with `restarting`, that lifecycle's, sharing its identities. */
	public function new(declarations:Null<DeclarationIndex>, ?initial:DeclarationStage = Declared,
			?restarting:DeclarationLifecycle) {
		if (restarting != null) {
			ids = restarting.ids;
			positions = restarting.positions;
			current = [for (_ in ids) initial];
			return;
		}
		ids = [];
		current = [];
		positions = [];
		if (declarations != null)
			for (symbol in declarations.symbols) {
				var position = positions.get(symbol.id);
				if (position == null) {
					positions.set(symbol.id, ids.length);
					ids.push(symbol.id);
					current.push(initial);
				} else
					current[position] = initial;
			}
	}

	/** The same declarations, each at `initial`: a lifecycle of its own that shares this one's identities. */
	public function restarted(initial:DeclarationStage):DeclarationLifecycle
		return new DeclarationLifecycle(null, initial, this);

	public function stage(id:DeclarationId):DeclarationStage {
		var position = positions.get(id);
		if (position == null)
			throw new InternalError('Unknown declaration lifecycle identity "$id"');
		return current[position];
	}

	public function advanceAll(next:DeclarationStage):Void
		for (position in 0...ids.length) {
			var stage = current[position];
			if ((next:Int) < (stage:Int))
				continue;
			if ((next:Int) > (stage:Int) + 1)
				throw new InternalError('Declaration "${ids[position]}" cannot advance from ${name(stage)} to ${name(next)}');
			current[position] = next;
		}

	public function requireAtLeast(required:DeclarationStage):Void
		for (position in 0...ids.length)
			if ((current[position]:Int) < (required:Int))
				throw new InternalError('Declaration "${ids[position]}" is ${name(current[position])}; ${name(required)} is required');

	public function snapshot():Map<String, DeclarationStage>
		return [for (position in 0...ids.length) ids[position] => current[position]];

	public static function name(stage:DeclarationStage):String
		return switch stage {
			case Declared: "declared";
			case ShapeConnected: "shape-connected";
			case SignatureTyped: "signature-typed";
			case BodyTyped: "body-typed";
			case Finalized: "finalized";
			default: "unknown";
		};
}
