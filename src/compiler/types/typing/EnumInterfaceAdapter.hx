package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstFunction;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import haxe.crypto.Sha256;

/** An enum obtains an object only at an explicit interface conversion boundary. */
class EnumInterfaceAdapter {
 public static function name(type:CompilerType, interfaceType:CompilerType):String
  return "$enum-interface:" + Sha256.encode(compiler.semantic.SemanticSignature.type(type) + ":" +
   compiler.semantic.SemanticSignature.type(interfaceType)).substr(0, 32);

 public static function request(session:TypingSession, type:CompilerType, interfaceType:CompilerType, span:SourceSpan):String {
  var key = name(type, interfaceType);
  if (!session.enumInterfaceAdapters.exists(key))
   session.enumInterfaceAdapters.set(key, {type: type, interfaceType: interfaceType, origin: session.currentContext.name, span: span});
  return key;
 }

 public static function generate(session:TypingSession):Array<TypedClass> {
  var names = [for (key in session.enumInterfaceAdapters.keys()) key];
  names.sort(Reflect.compare);
  return [for (key in names) build(session, key)];
 }

 static function build(session:TypingSession, key:String):TypedClass {
  var request = session.enumInterfaceAdapters.get(key);
  if (request == null) throw 'Missing enum interface adapter "$key"';
  var interfaceName = switch request.interfaceType {
   case TInstance(NominalKind.Interface, name, _): name;
   default: throw 'Invalid enum interface adapter contract "$key"';
  };
  var enumName = switch request.type {
   case TInstance(NominalKind.Enum, name, _): name;
   default: throw 'Invalid enum interface adapter value "$key"';
  };
  var ownerType:CompilerType = TInstance(NominalKind.Class, key, []), span = request.span,
   receiver = new TypedExpression(TLocal("this"), ownerType, span),
   payload = new TypedExpression(TField(receiver, "value"), request.type, span),
   constructor:TypedFunction = {
    name: key + ".new", role: OtherFunction, origin: request.origin, originKind: Helper, owner: key, isStatic: false, isConstructor: true,
    arguments: [{name: "value", type: request.type}], result: TVoid,
    statements: [TFieldAssign(receiver, "value", new TypedExpression(TLocal("value"), request.type, span), span), TReturnVoid(span)],
    cells: [], cellCaptures: [], span: span
   }, methods:Array<TypedFunction> = [constructor], seen:Map<String, Bool> = [];
  function addMethods(interfaceType:CompilerType):Void {
   var name = switch interfaceType { case TInstance(NominalKind.Interface, value, _): value; default: throw "Invalid interface base"; };
   var declaration = session.interfaceDecls.get(name);
   if (declaration == null) throw 'Missing interface "$name"';
   var substitutions = session.representation.nominalSubstitutions(interfaceType);
   for (base in declaration.bases)
    addMethods(session.declarations.resolve(base, declaration.span, substitutions));
   for (contract in declaration.methods) {
    if (seen.exists(contract.name)) continue;
    seen.set(contract.name, true);
    var implementation = EnumConformanceMethods.method(session, request.type, contract.name);
    if (implementation == null) throw 'Missing enum method "$enumName.${contract.name}"';
    var actualArguments = switch request.type { case TInstance(_, _, arguments): arguments; default: []; };
    var enumDeclaration = session.enumDecls.get(enumName), enumSubstitutions:Map<String, CompilerType> = [];
    if (enumDeclaration == null) throw 'Missing enum declaration "$enumName"';
    for (index in 0...enumDeclaration.typeParameters.length)
     enumSubstitutions.set(enumDeclaration.typeParameters[index], index < actualArguments.length ? actualArguments[index]
      : TTypeParameter(enumName, enumDeclaration.typeParameters[index]));
    var args = [for (argument in implementation.arguments) {name: argument.name, type: session.declarations.resolve(argument.type, argument.span, enumSubstitutions)}];
    var result = session.declarations.resolve(implementation.result, implementation.span, enumSubstitutions);
    EnumConformanceMethods.request(session, request.type, contract.name, request.origin, span);
    var callArguments = [payload];
    for (argument in args) callArguments.push(new TypedExpression(TLocal(argument.name), argument.type, span));
    var call = new TypedExpression(TCall(EnumConformanceMethods.name(request.type, contract.name), callArguments), result, span);
    var body:Array<TypedStatement> = switch result {
     case TVoid: [TExpression(call, span), TReturnVoid(span)];
     default: [TReturn(call, span)];
    };
    methods.push({name: key + "." + contract.name, role: OtherFunction, origin: request.origin, originKind: Helper, owner: key, isStatic: false, isConstructor: false,
     arguments: args, result: result, statements: body, cells: [], cellCaptures: [], span: span});
   }
  }
  addMethods(request.interfaceType);
  var field:TypedField = {name: "value", metadata: [], type: request.type, initializer: null, inlineValue: null,
   readAccess: null, writeAccess: null, isStatic: false, isInline: false, isFinal: true, span: span};
  return {name: key, isValue: false, isFlat: false, isPortable: false, isNativeValue: false, nativeLayouts: [],
   base: null, interfaces: [interfaceName], fields: [field], methods: methods, span: span};
 }
}
