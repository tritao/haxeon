package compiler.ir.pipeline;

import compiler.ir.analysis.IrTypeAwareWalk.IrWalkResult;
import compiler.ir.gen.IrGenerator;
import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrEnum;
import compiler.ir.model.Ir.IrInterface;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrStaticField;
import compiler.ir.model.IrFunction;

/**
 * The program `IrProgramAssembler.assemble` builds while the stages of `IrPipeline.assembly` run: the functions and the tables, each
 * null when the caller gave none, and what one stage leaves for a later one. The last stages turn it into `program`.
 */
class IrAssembly {
	public final generator:IrGenerator;
	public var functions:Array<IrFunction>;
	public var natives:Null<Array<IrNative>>;
	public var objects:Null<Array<IrObject>>;
	public var interfaces:Null<Array<IrInterface>>;
	public var enums:Null<Array<IrEnum>>;
	public var staticFields:Null<Array<IrStaticField>>;
	public var cNatives:Null<Array<IrCNative>>;
	public var reflectableObjects:Null<Array<String>>;

	/** The walk the Dynamic dispatch of enums and structs is decided by, in a pruned build. */
	public var dispatchWalk:Null<IrWalkResult> = null;

	/** The functions `dispatchWalk` does not reach. */
	public var unreached:Null<Map<String, Bool>> = null;

	/** The input of the enum Dynamic dispatch. */
	public var reflectionInput:Null<IrProgram> = null;

	/** The natives the prune found called; null without the prune. */
	public var reachedNatives:Null<Map<String, Bool>> = null;

	/** Where the functions a stage generated start, for the stage after it that rewrites only those. */
	public var generatedStart:Int = 0;

	/** The program with its enum storage chosen, for the inline enum lowering. */
	public var enumInput:Null<IrProgram> = null;

	/** The finished program. */
	public var program:Null<IrProgram> = null;

	public function new(generator:IrGenerator, functions:Array<IrFunction>, natives:Null<Array<IrNative>>,
			objects:Null<Array<IrObject>>, interfaces:Null<Array<IrInterface>>, enums:Null<Array<IrEnum>>,
			staticFields:Null<Array<IrStaticField>>, cNatives:Null<Array<IrCNative>>,
			reflectableObjects:Null<Array<String>>) {
		this.generator = generator;
		this.functions = functions;
		this.natives = natives;
		this.objects = objects;
		this.interfaces = interfaces;
		this.enums = enums;
		this.staticFields = staticFields;
		this.cNatives = cNatives;
		this.reflectableObjects = reflectableObjects;
	}
}
