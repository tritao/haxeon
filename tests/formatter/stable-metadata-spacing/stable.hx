// Metadata arguments follow the name directly; after a space, the parenthesis starts the expression the metadata is on, so the
// formatter keeps that space: removing it would make `(a + b)` the metadata's argument.
function main():Int {
	@:privateAccess item.secret = 1;
	var total = @:privateAccess (item.secret + item.hidden());
	return @:keep(1 + 2) + @:keep (3);
}
