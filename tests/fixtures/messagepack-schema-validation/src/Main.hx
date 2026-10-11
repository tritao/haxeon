import haxe.Json;
import haxeon.wire.MessagePackSchema;
import haxeon.wire.MessagePackSchema.MessagePackSchemaSourceKind;
import sys.io.File;

interface SchemaResource {
}
interface SchemaRole {
}
interface SchemaBase extends SchemaResource {
}
interface GenericMarker < T > {
}

@:annotation struct Range {
  public var min:Float;
  public var max:Float;
}

@:annotation struct maxLength {
  public var value:Int;
}

@:value @:repr("C") class SchemaNative {
  public var count:Int;
}

struct SchemaLeaf {
  public var zero:Int = 0;
  public var optional:Null<Int> = null;
  public var narrow:UInt8 = 250;
  public var ratio:Float32 = 0.1;
  public var absent:Int;
  @:Range(0.0, 4294967295.0) public var unsigned32:UInt32 = 0;
  public var signed32:Int32 = 123456789;
  public var highBit:UInt32 = -1;
}
struct SchemaRoot:SchemaBase, GenericMarker<Int>, SchemaRole {
  public var leaf:SchemaLeaf;
  public var title:String = "root";
}

struct SchemaUnicodeDefault {
  @:maxLength(1) public var title:String = "é";
}

function rejects(action:Void -> Void):Bool {
  try {
    action();
  } catch (_:Dynamic) {
    return true;
  }
  return false;
}

function field(fields:Array<Dynamic>, name:String):Dynamic {
  for (value in fields) if (Reflect.field(value, "name") == name) return value;
  throw 'missing schema fixture field "$name"';
}

function main():Int {
  var artifactPath = Sys.getEnv("HAXEON_SCHEMA_VALIDATION_ARTIFACT");
  if (artifactPath == null) throw "HAXEON_SCHEMA_VALIDATION_ARTIFACT must name the generated descriptor artifact";
  var json = File.getContent(artifactPath),
    info:Dynamic = typeInfo<SchemaRoot>(), schema = MessagePackSchema.fromJson(json);
  schema.requireDescriptor(info.hash, info.type);
  var sourceFacts = schema.requireSourceFacts(info.hash, info.type);
  if (sourceFacts.sourceKind != MessagePackSchemaSourceKind.Struct || sourceFacts.interfaces.join(",")
    != "interface:GenericMarker<Int>,interface:SchemaBase<>,interface:SchemaResource<>,interface:SchemaRole<>") return 8;
  sourceFacts.interfaces.pop();
  if (schema.requireSourceFacts(info.hash, info.type).interfaces.length != 4) return 9;
  var nativeInfo:Dynamic = typeInfo<SchemaNative>();
  schema.requireDescriptor(nativeInfo.hash, nativeInfo.type);
  var nativeFacts = schema.requireSourceFacts(nativeInfo.hash, nativeInfo.type);
  if (nativeInfo.type != "native-value:SchemaNative<>" || nativeFacts.sourceKind
    != MessagePackSchemaSourceKind.NativeValue || nativeFacts.interfaces.length != 0) return 15;
  var unicodeInfo:Dynamic = typeInfo<SchemaUnicodeDefault>();
  schema.requireDescriptor(unicodeInfo.hash, unicodeInfo.type);
  var unicodeDefault = schema.fieldDefaultValue(unicodeInfo.hash, unicodeInfo.type, ["title"]);
  if (unicodeDefault == null || unicodeDefault.type != "String" || unicodeDefault.value != "é") return 17;
  var zero = schema.fieldDefaultValue(info.hash, info.type, ["leaf", "zero"]), optional = schema.fieldDefaultValue(
    info.hash,
    info.type,
    [
      "leaf",
      "optional"
    ]
  ), narrow = schema.fieldDefaultValue(
    info.hash,
    info.type,
    [
      "leaf",
      "narrow"
    ]
  ), ratio = schema.fieldDefaultValue(
    info.hash,
    info.type,
    [
      "leaf",
      "ratio"
    ]
  ), absent = schema.fieldDefaultValue(
    info.hash,
    info.type,
    [
      "leaf",
      "absent"
    ]
  ), title = schema.fieldDefaultValue(
    info.hash,
    info.type,
    ["title"]
  );
  var unsigned32 = schema.fieldDefaultValue(info.hash,
    info.type, ["leaf", "unsigned32"]), signed32 = schema.fieldDefaultValue(
      info.hash,
      info.type,
      [
        "leaf",
        "signed32"
      ]
    ), highBit = schema.fieldDefaultValue(
      info.hash,
      info.type,
      [
        "leaf",
        "highBit"
      ]
    );
  if (zero == null || zero.type != "Int" || zero.value != 0
    || optional == null || optional.type != "Null" || optional.value != null || narrow == null || narrow.type != "Int"
    || narrow.value != 250 || ratio == null || ratio.type != "Float" || ratio.value != 0.10000000149011612
    || absent != null || title == null || title.type != "String" || title.value != "root") return 1;
  if (unsigned32 == null
    || unsigned32.type != "Int" || unsigned32.value != 0 || signed32 == null || signed32.type != "Int"
    || signed32.value != 123456789 || highBit == null || highBit.type != "Int" || highBit.value != -1) return 16;
  if (!rejects(function() MessagePackSchema.fromJson('{"formatVersion":2,"descriptors":[]}'))) return 2;
  if (!rejects(function() schema.fieldDefaultValue(info.hash, info.type, ["leaf", "missing"]))) return 3;
  if (!rejects(function() MessagePackSchema.fromJson(StringTools.replace(json,
    info.hash, StringTools.lpad("", "0", 64))))) return 4;
  var sourceKindTamper:Dynamic = Json.parse(json), sourceKindDescriptors:Array<Dynamic> = cast Reflect.field(
    sourceKindTamper,
    "descriptors"
  );
  for (descriptor in sourceKindDescriptors) if (Reflect.field(descriptor, "hash") == info.hash) Reflect.setField(
    descriptor,
    "sourceKind",
    "class"
  );
  if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(sourceKindTamper)))) return 10;
  var interfaceOrderTamper:Dynamic = Json.parse(json), interfaceDescriptors:Array<Dynamic> = cast Reflect.field(
    interfaceOrderTamper,
    "descriptors"
  );
  for (descriptor in interfaceDescriptors) if (Reflect.field(descriptor, "hash") == info.hash) Reflect.setField(
    descriptor,
    "interfaces",
    [
      "interface:SchemaRole<>",
      "interface:SchemaResource<>"
    ]
  );
  if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(interfaceOrderTamper)))) return 11;
  var legacyPath = Sys.getEnv("HAXEON_SCHEMA_LEGACY_ARTIFACT");
  if (legacyPath == null) throw "HAXEON_SCHEMA_LEGACY_ARTIFACT must name the pre-conformance fixture";
  var legacy = MessagePackSchema.fromJson(File.getContent(legacyPath)),
    legacyHash = "c53ad0bec33902b10b2cb636be67e3b3c5e32eb198e08ea7fe8e76f88272e9ee",
    legacyType = "class:LegacySchemaProbe<>";
  legacy.requireDescriptor(legacyHash, legacyType);
  if (legacy.sourceFacts(legacyHash, legacyType) != null) return 12;
  if (!rejects(function() legacy.requireSourceFacts(legacyHash, legacyType))) return 13;
  var legacyDefault = legacy.fieldDefaultValue(legacyHash, legacyType, ["value"]);
  if (legacyDefault == null || legacyDefault.type != "Int" || legacyDefault.value != 7) return 14;
  var wrongType:Dynamic = Json.parse(json),
    descriptors:Array<Dynamic> = cast Reflect.field(wrongType, "descriptors"), root:Dynamic = null;
  for (descriptor in descriptors) if (Reflect.field(descriptor, "hash") == info.hash) root = descriptor;
  var leaf = field(cast Reflect.field(root, "fields"), "leaf"), leafFields:Array<Dynamic> = cast Reflect.field(
    leaf,
    "fields"
  );
  Reflect.setField(field(leafFields, "zero"), "defaultValue", {type: "String", value: "wrong"}
  );
  if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(wrongType)))) return 5;
  var outOfRange:Dynamic = Json.parse(json), outDescriptors:Array<Dynamic> = cast Reflect.field(
    outOfRange,
    "descriptors"
  );
  for (descriptor in outDescriptors) if (Reflect.field(descriptor, "hash") == info.hash) {
    var outLeaf = field(cast Reflect.field(descriptor,
      "fields"), "leaf"), outLeafFields:Array<Dynamic> = cast Reflect.field(
        outLeaf,
        "fields"
      );
    Reflect.setField(field(outLeafFields, "narrow"), "defaultValue", {type: "Int", value: 256}
    );
  }
  if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(outOfRange)))) return 6;
  var outOfFloat32Range:Dynamic = Json.parse(json), float32Descriptors:Array<Dynamic> = cast Reflect.field(
    outOfFloat32Range,
    "descriptors"
  );
  for (descriptor in float32Descriptors) if (Reflect.field(descriptor, "hash") == info.hash) {
    var floatLeaf = field(cast Reflect.field(descriptor,
      "fields"), "leaf"), floatLeafFields:Array<Dynamic> = cast Reflect.field(
        floatLeaf,
        "fields"
      );
    Reflect.setField(field(floatLeafFields, "ratio"), "defaultValue", {type: "Float", value: 3.5 * Math.pow(10, 38)}
    );
  }
  if (!rejects(function() MessagePackSchema.fromJson(Json.stringify(outOfFloat32Range)))) return 7;
  return 42;
}
