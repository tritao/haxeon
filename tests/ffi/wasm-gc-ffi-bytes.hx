import GcBytes;
import haxe.io.Bytes;

function main():Int {
	var modified = GcBytes.modify(37);
	if (modified.status != 9 || modified.value != 42)
		return 0;
	var stored = GcBytes.store();
	if (stored.value != 11 || stored.count != 0x12345678)
		return 0;
	var point = GcBytes.storePoint();
	if (point.get_x() != 17 || point.get_y() != 25)
		return 0;
	point.set_x(20);
	point.set_y(30);
	point = GcBytes.shiftPoint(point);
	if (point.get_x() != 21 || point.get_y() != 32)
		return 0;
	var valuePoint = GcBytes.makePoint(20);
	if (valuePoint.get_x() != 20
		|| valuePoint.get_y() != 22
		|| GcBytes.readPoint(valuePoint) != 42
		|| GcBytes.sumPoint(valuePoint) != 42)
		return 0;
	var context = GcBytes.borrowedContext(),
		outputContext = GcBytes.storeContext(),
		nullContext = GcBytes.storeNullContext();
	if (context == null
		|| context.isClosed()
		|| GcBytes.inspectContext(context) != 42
		|| outputContext == null
		|| GcBytes.inspectContext(outputContext) != 42
		|| nullContext != null)
		return 0;
	var ownedContext = GcBytes.ownedContext(),
		nullableOwnedContext = GcBytes.nullableOwnedContext(1),
		nullOwnedContext = GcBytes.nullableOwnedContext(0),
		outputOwnedContext = GcBytes.storeOwnedContext(),
		nullOutputOwnedContext = GcBytes.storeNullOwnedContext();
	if (ownedContext.isClosed()
		|| GcBytes.inspectContext(ownedContext.borrow()) != 42
		|| nullableOwnedContext == null
		|| nullableOwnedContext.isClosed()
		|| GcBytes.inspectContext(nullableOwnedContext.borrow()) != 42
		|| nullOwnedContext != null
		|| outputOwnedContext == null
		|| outputOwnedContext.isClosed()
		|| GcBytes.inspectContext(outputOwnedContext.borrow()) != 42
		|| nullOutputOwnedContext != null)
		return 0;
	if (!ownedContext.close()
		|| ownedContext.close()
		|| !ownedContext.isClosed()
		|| GcBytes.inspectContext(ownedContext.borrow()) != 0
		|| !nullableOwnedContext.close()
		|| nullableOwnedContext.close()
		|| !outputOwnedContext.close()
		|| outputOwnedContext.close())
		return 0;
	var payload = Bytes.ofString("gc bytes");
	if (GcBytes.inspect(payload) != 42)
		return 0;
	var backing = Bytes.ofString("!gc bytes?"),
		view = Bytes.view(backing, 1, 8);
	if (GcBytes.mutate(view) != 17
		|| backing.get(0) != 33
		|| backing.get(1) != 84
		|| backing.get(8) != 33
		|| backing.get(9) != 63)
		return 0;
	var output = GcBytes.read(7);
	if (output.status != 9 || output.data.length != 5 || output.data.get(0) != 104 || output.data.get(4) != 111)
		return 0;
	var fetched = GcBytes.fetch();
	if (fetched.length != 8 || fetched.get(0) != 70 || fetched.get(7) != 33)
		return 0;
	if (GcBytes.optional() != null)
		return 0;
	var owned = GcBytes.fetchOwned();
	if (owned.length != 4 || owned.get(0) != 79 || owned.get(3) != 33)
		return 0;
	var largePayload = Bytes.alloc(70000), index = 0;
	while (index < largePayload.length) {
		largePayload.set(index, index & 255);
		index = index + 1;
	}
	return GcBytes.inspect(largePayload);
}
