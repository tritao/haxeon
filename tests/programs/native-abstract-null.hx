function empty():hl.Abstract<"test_handle">
	return null;

function main():Int
	return empty() == null ? 42 : 0;
