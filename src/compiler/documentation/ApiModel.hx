package compiler.documentation;

/** Public declarations in a successfully typed source graph (docs/design/API_MODEL.md). */
typedef ApiModel = {
	final version:Int;

	/** The modules described, by path: the API itself. The other declarations are there because the API refers to them. */
	final described:Array<String>;

	final modules:Array<ApiModule>;
	final types:Array<ApiDeclaration>;
}

/** A module's own public functions and variables: those declared at its top level, outside any type. */
typedef ApiModule = {
	final path:String;

	/** The package its source belongs to (`package` in JSON); null for the standard library's. */
	final packageName:Null<String>;

	final file:String;
	final members:Array<ApiMember>;
}

typedef ApiDeclaration = {
	final source:ApiSource;
	final path:String;
	final module:String;

	/** The package its source belongs to (`package` in JSON); null for the standard library's. */
	final packageName:Null<String>;
	final kind:String;
	final isExtern:Bool;
	final typeParameters:Array<ApiTypeParameter>;
	final supertypes:Array<ApiType>;
	final interfaces:Array<ApiType>;
	final underlying:Null<ApiType>;
	final from:Array<ApiType>;
	final to:Array<ApiType>;
	final members:Array<ApiMember>;
}

typedef ApiSource = {
	final visibility:String;
	final position:{file:String, line:Int};
	final metadata:Array<ApiAnnotation>;
	final documentation:Null<ApiDocumentation>;
}

typedef ApiAnnotation = {
	final name:String;
	final arguments:Array<String>;
}

typedef ApiDocumentation = {
	final markdown:String;
	final tags:Array<{name:String, parameter:Null<String>, text:String}>;
}

typedef ApiMember = {
	final source:ApiSource;
	final kind:String;
	final name:String;
	final isStatic:Bool;
	final ?type:ApiType;

	/** A field written `final`: set once, by its declaration or the constructor. */
	final ?isFinal:Bool;

	final ?get:String;
	final ?set:String;
	final ?arguments:Array<ApiArgument>;
	final ?result:ApiType;
	final ?typeParameters:Array<ApiTypeParameter>;
	final ?operatorText:String;
	final ?conversion:String;

	/** An enum case's per-case constant values, in the enum's declaration order (docs/design/ENUM_MEMBERS.md). */
	final ?constants:Array<ApiCaseConstant>;

	/** A raw-value enum case's code, as written or implied (`enum E:Int { A = 1; }`). */
	final ?rawValue:String;

	/**
	 * For an instance field, property or method of a class or interface: the supertype whose member of the same name this
	 * one overrides or implements (`ApiModelBuilder.overridden`), whose comment documents it when it has none of its own.
	 */
	final ?overrides:String;
}

/** One case's value for a per-case constant: its source text, and whether the case leaves it at the default. */
typedef ApiCaseConstant = {
	final name:String;
	final value:String;
	final isDefault:Bool;
}

typedef ApiArgument = {
	final name:Null<String>;
	final type:ApiType;
	final optional:Bool;
	final defaultValue:Null<String>;
}

typedef ApiTypeParameter = {
	final name:String;
	final constraints:Array<ApiType>;
}

/** A tagged type tree. Only the properties belonging to its tag are present. */
typedef ApiType = {
	final kind:String;
	final ?path:String;
	final ?name:String;
	final ?owner:String;
	final ?arguments:Array<ApiType>;
	final ?optional:Array<Bool>;
	final ?result:ApiType;
	final ?fields:Array<{name:String, type:ApiType, optional:Bool, isFinal:Bool}>;
	final ?id:Int;
}
