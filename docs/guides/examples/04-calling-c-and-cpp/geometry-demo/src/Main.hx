import Circle;
import Geometry;

function main() {
	// Numbers and records: a Point is the C struct geo_point, laid out as C lays it out.
	var origin = new Point();
	var corner = new Point();
	corner.x = 3.0;
	corner.y = 4.0;
	Sys.println('distance: ${Geometry.distance(origin, corner)}');

	// A pointer parameter lets C change the record in place.
	Geometry.translate(corner, 1.0, 1.0);
	Sys.println('moved to: ${corner.x}, ${corner.y}');

	// Strings cross as UTF-8.
	Sys.println('bytes in "héllo": ${Geometry.textLength("héllo")}');

	// An owned handle: close() calls geo_path_destroy once, however often it is called.
	var path = Geometry.pathCreate();
	Geometry.pathAdd(path.borrow(), origin);
	Geometry.pathAdd(path.borrow(), corner);
	Sys.println('path length: ${Geometry.pathLength(path.borrow())}');
	path.close();

	// A C++ class: create() runs its constructor, close() its destructor.
	var circle = Circle.create(1.0);
	circle.scale(2.0);
	Sys.println('circle area: ${circle.area()}');
	circle.close();
}
