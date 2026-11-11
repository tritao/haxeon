package compiler.semantic;

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
	final ids:Array<String> = [];

	final current:Array<DeclarationStage> = [];
	final positions:Map<String, Int> = [];

	public function new(declarations:DeclarationIndex, ?initial:DeclarationStage = Declared)
		for (symbol in declarations.symbols) {
			var position = positions.get(symbol.id);
			if (position == null) {
				positions.set(symbol.id, ids.length);
				ids.push(symbol.id);
				current.push(initial);
			} else
				current[position] = initial;
		}

	public function stage(id:DeclarationId):DeclarationStage {
		var position = positions.get(id);
		if (position == null)
			throw 'Unknown declaration lifecycle identity "$id"';
		return current[position];
	}

	public function advanceAll(next:DeclarationStage):Void
		for (position in 0...ids.length) {
			var stage = current[position];
			if ((next : Int) < (stage : Int))
				continue;
			if ((next : Int) > (stage : Int) + 1)
				throw 'Declaration "${ids[position]}" cannot advance from ${name(stage)} to ${name(next)}';
			current[position] = next;
		}

	public function requireAtLeast(required:DeclarationStage):Void
		for (position in 0...ids.length)
			if ((current[position] : Int) < (required : Int))
				throw 'Declaration "${ids[position]}" is ${name(current[position])}; ${name(required)} is required';

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
