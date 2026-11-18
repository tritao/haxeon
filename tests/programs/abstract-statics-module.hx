// An abstract's static variables read and written from another module: through an import and by the full path.
import abstractstatics.Units;

function main():Int {
	var units:Units = 2;
	if (units.scaled() != 6)
		return 1;
	Units.scale = 5;
	return units.scaled() + abstractstatics.Units.names.length + 31;
}
