import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataRegistry;
import runtime.hashlink.HlTypeKind;
import runtime.memory.RawPtr;

function buildGeneration():HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		type = generation.builder.primitive(HlTypeKind.Int32Type);
	generation.addType(type);
	generation.defineModule([RawPtr.nullPtr()], [type]);
	return generation;
}

function main():Int {
	var registry = new HlMetadataRegistry(),
		first = buildGeneration(),
		firstPublication = registry.publish(first),
		firstType = firstPublication.types.offset(0).load(),
		second = buildGeneration(),
		secondPublication = registry.publish(second),
		current = registry.currentPublication();
	var switched = registry.revision == 2
		&& registry.retiredCount == 1
		&& current.moduleContext == secondPublication.moduleContext
		&& current.types.offset(0).load() != firstType
		&& first.type(0) == firstType;
	var disposed = registry.disposeRetired() == 1 && registry.retiredCount == 0,
		firstReleased = false;
	try
		first.type(0)
	catch (error:Dynamic)
		firstReleased = true;
	registry.dispose();
	return switched && disposed && firstReleased ? 42 : 1;
}
