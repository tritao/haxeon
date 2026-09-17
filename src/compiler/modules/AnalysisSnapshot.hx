package compiler.modules;

import compiler.Source.SourceFile;
import compiler.semantic.SemanticModel;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Token;

/** Provenance of an atomically published compiler/editor analysis snapshot. */
enum AnalysisSnapshotKind {
	Exact;
	Recovered;
	LastGood;
}

/**
 * Source, syntax, semantic model, revision, and provenance published as one
 * unit. A query must never combine these artifacts from different revisions.
 */
class AnalysisSnapshot {
	public final source:SourceFile;
	final tokenData:Array<Token>;
	public var tokens(get, never):Array<Token>;
	public final ast:AstProgram;
	public final semanticModel:Null<SemanticModel>;
	public final revision:Int;
	public final kind:AnalysisSnapshotKind;
	public final stale:Bool;
	public final recovered:Bool;

	public function new(source:SourceFile, tokens:Array<Token>, ast:AstProgram, semanticModel:Null<SemanticModel>, revision:Int,
			kind:AnalysisSnapshotKind) {
		if (semanticModel != null) {
			if (semanticModel.revision != revision)
				throw "Semantic snapshot revision does not match its semantic model";
			if (semanticModel.source != source)
				throw "Semantic snapshot source does not match its semantic model";
			if (!semanticModel.isFrozen)
				throw "Semantic snapshot cannot publish an unfrozen semantic model";
		}
		this.source = source;
		this.tokenData = tokens.copy();
		this.ast = ast;
		this.semanticModel = semanticModel;
		this.revision = revision;
		this.kind = kind;
		this.stale = kind == AnalysisSnapshotKind.LastGood;
		this.recovered = kind == AnalysisSnapshotKind.Recovered;
	}

	public static function exact(source:SourceFile, tokens:Array<Token>, ast:AstProgram, semanticModel:Null<SemanticModel>, revision:Int):AnalysisSnapshot
		return new AnalysisSnapshot(source, tokens, ast, semanticModel, revision, AnalysisSnapshotKind.Exact);

	public static function recoveredSnapshot(source:SourceFile, tokens:Array<Token>, ast:AstProgram, semanticModel:Null<SemanticModel>, revision:Int):AnalysisSnapshot
		return new AnalysisSnapshot(source, tokens, ast, semanticModel, revision, AnalysisSnapshotKind.Recovered);

	public static function lastGood(snapshot:AnalysisSnapshot):AnalysisSnapshot
		return new AnalysisSnapshot(snapshot.source, snapshot.tokens, snapshot.ast, snapshot.semanticModel, snapshot.revision, AnalysisSnapshotKind.LastGood);

	public inline function isCurrent(currentRevision:Int):Bool
		return revision == currentRevision && !stale;

	/** Return a detached token view so published snapshots cannot be mutated. */
	function get_tokens():Array<Token>
		return tokenData.copy();
}
