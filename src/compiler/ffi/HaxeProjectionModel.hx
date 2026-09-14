package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;
import compiler.ffi.HxiProjectionProfile.HxiResultErrorProjection;
import compiler.ffi.HxiProjectionProfile.HxiProjectionProfile;
import compiler.ffi.HxiSemantics.HxiSemanticParameterKind;
import compiler.ffi.HxiSemantics.HxiSemanticResultKind;

typedef ProjectedEnumValue = {
	final nativeName:String;
	final name:String;
	final value:String;
}

typedef ProjectedEnum = {
	final nativeName:String;
	final name:String;
	final flags:Bool;
	final values:Array<ProjectedEnumValue>;
}

typedef ProjectedStructField = {
	final nativeName:String;
	final name:String;
	final type:HxiType;
	final offset:Null<Int>;
}

typedef ProjectedStruct = {
	final nativeName:String;
	final name:String;
	final size:Int;
	final alignment:Int;
	final fields:Array<ProjectedStructField>;
}

typedef ProjectedOwnedHandle = {
	final nativeName:String;
	final name:String;
	final destroy:String;
}

enum ProjectedHandleKind {
	OpaqueHandle;
	ValueHandle;
}

typedef ProjectedHandle = {
	final nativeName:String;
	final name:String;
	final kind:ProjectedHandleKind;
	final ownedName:Null<String>;
	final owned:Null<ProjectedOwnedHandle>;
}

typedef ProjectedCallback = {
	final nativeName:String;
	final name:String;
	final arguments:Array<HxiAbiValue>;
	final result:HxiAbiValue;
	final callConvention:String;
}

typedef ProjectedOutputResult = {
	final parameter:String;
	final type:String;
	final owned:Bool;
	final destroy:Null<String>;
	final semantics:HxiSemanticParameterKind;
}

typedef ProjectedCheckedFunction = {
	final name:String;
	final returnType:String;
	final outputs:Array<ProjectedOutputResult>;
	final policy:HxiResultErrorProjection;
}

enum ProjectedOutputStrategy {
	NoOutputWrapper;
	OutputValues;
	OutputBuffer;
	OutputArray;
}

typedef ProjectedFunction = {
	final nativeName:String;
	final name:String;
	final rawName:String;
	final nativeSignature:HxiFunctionAbi;
	final resultType:String;
	final outputs:Array<ProjectedOutputResult>;
	final hasOutputParameters:Bool;
	final outputStrategy:ProjectedOutputStrategy;
	final ownedResult:Null<ProjectedOwnedHandle>;
	final checked:Null<ProjectedCheckedFunction>;
	final byteSliceName:Null<String>;
}

/** Resolved Haxe declarations and wrappers that the emitter will print. */
class HaxeProjectionModel {
	public final source:HxiInterface;
	public final omitted:Null<Map<String, Bool>>;
	public final visibleDeclarations:Null<Map<String, compiler.ffi.HxiModel.HxiDeclaration>>;
	public final abi:HxiAbi;
	public final profile:HxiProjectionProfile;
	public final enums:Array<ProjectedEnum>;
	public final structures:Array<ProjectedStruct>;
	public final handles:Array<ProjectedHandle>;
	public final callbacks:Array<ProjectedCallback>;
	public final functions:Array<ProjectedFunction>;

	public function new(source:HxiInterface, omitted:Null<Map<String, Bool>>, visibleDeclarations:Null<Map<String, compiler.ffi.HxiModel.HxiDeclaration>>,
			abi:HxiAbi, profile:HxiProjectionProfile, enums:Array<ProjectedEnum>, structures:Array<ProjectedStruct>, handles:Array<ProjectedHandle>,
			callbacks:Array<ProjectedCallback>, functions:Array<ProjectedFunction>) {
		this.source = source;
		this.omitted = omitted;
		this.visibleDeclarations = visibleDeclarations;
		this.abi = abi;
		this.profile = profile;
		this.enums = enums;
		this.structures = structures;
		this.handles = handles;
		this.callbacks = callbacks;
		this.functions = functions;
	}
}
