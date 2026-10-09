# Source conformance facts in type descriptors

This checkpoint adds compiler-emitted source declaration facts for descriptor roots. It does not decide which interfaces qualify a type for a World catalog, and it does not prove that a loaded binary matches a descriptor.

## API

`typeInfo<T>()` now exposes `sourceKind` and `interfaces` alongside its existing descriptor fields. For compiler-emitted JSON sidecars, `haxeon.wire.MessagePackSchema` exposes:

```haxe
import haxeon.wire.MessagePackSchema;
import haxeon.wire.MessagePackSchema.MessagePackSchemaSourceKind;
import sys.io.File;

var schema = MessagePackSchema.fromJson(File.getContent(descriptorPath));
var info = typeInfo<MyResource>();
var facts = schema.requireSourceFacts(info.hash, info.type);
if (facts.sourceKind == MessagePackSchemaSourceKind.Struct
	&& facts.interfaces.indexOf("interface:domain.Resource<>") >= 0) {
	// Apply application-owned registration policy here.
}
```

`sourceKind` is a typed `MessagePackSchemaSourceKind` with `Struct`, `Class`, and `NativeValue` cases. `interfaces` contains canonical `SemanticSignature.type` identities, sorted and deduplicated. It includes directly declared and inherited interfaces after generic substitution. For example, a struct implementing `BaseResource` where `BaseResource extends Resource` reports both `interface:domain.BaseResource<>` and `interface:domain.Resource<>`; `Base<Int>` is reported as `interface:domain.Base<Int>`.

`sourceFacts(hash, type)` returns `null` when a supported legacy descriptor has no source facts. `requireSourceFacts(hash, type)` throws in that case, so callers making a role decision cannot interpret missing metadata as nonconformance. Both methods first require the requested hash and semantic type to identify a validated descriptor in the artifact.

## Artifact compatibility

- New compiler descriptors use descriptor schema version 5. Their source kind and effective interface list participate in the descriptor content hash.
- New binary descriptor containers use `HTD` format 4. The compiler binary codec accepts that version; previous binary versions are not decoded by this codec.
- New JSON sidecars use envelope format 4 and descriptor version 5.
- `MessagePackSchema` also accepts the previous JSON envelope format 3 with descriptor version 4. Those descriptors remain usable for existing field-default reads, but their conformance facts are unknown. JSON envelope/descriptor versions must match as a pair.
- The JSON hash check verifies that the fields agree with the compiler hash algorithm. It does not authenticate the producer: a party able to replace an artifact can recompute the hash.

## Boundaries

The facts describe compiler-resolved source declarations. A pair of interfaces such as `Resource` and `Component` is reported as-is; the consumer owns precedence, marker/catalog membership, registration rules, and diagnostics. Facts do not inspect a runtime value, confirm an implementation is loaded, or bind a descriptor to a binary or module provenance. Legacy descriptors stay unknown rather than being upgraded by guessing from their field shape.

The consumer must read the descriptor emitted for the same `typeInfo<T>()` identity and use both its hash and semantic type when querying `MessagePackSchema`. Source code that only reads the older typeInfo fields needs no migration; code that constructs a complete typeInfo anonymous value manually must provide the two new fields. Artifact producers should emit format 4/version 5. A consumer that can receive old JSON artifacts must handle `sourceFacts == null` or use `requireSourceFacts` and report its error.
