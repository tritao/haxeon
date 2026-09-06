enum ArrayPayload {
	Values(values:Array<Int>);
}

function sizeKind(payload:ArrayPayload):Int {
	return switch payload {
		case ArrayPayload.Values([]): 40;
		case ArrayPayload.Values(values): values.length;
	};
}

function main():Int {
	return sizeKind(ArrayPayload.Values([])) + sizeKind(ArrayPayload.Values([1, 2]));
}
