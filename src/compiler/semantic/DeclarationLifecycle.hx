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
	final stages:Map<String, DeclarationStage> = [];

	public function new(declarations:DeclarationIndex, ?initial:DeclarationStage = Declared)
		for (symbol in declarations.symbols)
			stages.set(symbol.id, initial);

	public function stage(id:DeclarationId):DeclarationStage {
		var result = stages.get(id);
		if (result == null)
			throw 'Unknown declaration lifecycle identity "$id"';
		return result;
	}

	public function advanceAll(next:DeclarationStage):Void
		for (id => current in stages) {
			if ((next : Int) < (current : Int))
				continue;
			if ((next : Int) > (current : Int) + 1)
				throw 'Declaration "$id" cannot advance from ${name(current)} to ${name(next)}';
			stages.set(id, next);
		}

	public function requireAtLeast(required:DeclarationStage):Void
		for (id => current in stages)
			if ((current : Int) < (required : Int))
				throw 'Declaration "$id" is ${name(current)}; ${name(required)} is required';

	public function snapshot():Map<String, DeclarationStage>
		return [for (id => state in stages) id => state];

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
