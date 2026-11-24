#ifndef GEOMETRY_H
#define GEOMETRY_H

#include <stdint.h>

/* Annotations the Haxeon importer reads; a C compiler ignores them. */
#define GEO_HANDLE __attribute__((annotate("hxi:handle")))
#define GEO_HANDLE_DESTROY(symbol) __attribute__((annotate("hxi:handle_destroy")))
#define GEO_OWNED __attribute__((annotate("hxi:owned")))

/* Text passed as UTF-8. The importer maps this typedef, and only this one, to a Haxe String. */
typedef const char *hxi_utf8;

typedef struct geo_point {
	double x;
	double y;
} geo_point;

/* The distance between two points. */
double geo_distance(const geo_point *a, const geo_point *b);

/* Moves `point` by (dx, dy) in place. */
void geo_translate(geo_point *point, double dx, double dy);

/* The number of bytes in `text` before its terminating zero. */
int32_t geo_text_length(hxi_utf8 text);

/* A path the library keeps: a list of points, named by a handle. Zero is no path. */
typedef uint32_t geo_path GEO_HANDLE GEO_HANDLE_DESTROY(geo_path_destroy);

/* A new, empty path, or zero when no more paths fit. The caller destroys it. */
geo_path geo_path_create(void) GEO_OWNED;

/* Adds a copy of `point` to the end of `path`. */
void geo_path_add(geo_path path, const geo_point *point);

/* The length of the line through the path's points, in order. */
double geo_path_length(geo_path path);

void geo_path_destroy(geo_path path);

#endif
