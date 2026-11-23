#include "geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

double geo_distance(const geo_point *a, const geo_point *b) {
	double dx = b->x - a->x;
	double dy = b->y - a->y;
	return sqrt(dx * dx + dy * dy);
}

void geo_translate(geo_point *point, double dx, double dy) {
	point->x += dx;
	point->y += dy;
}

int32_t geo_text_length(hxi_utf8 text) {
	return (int32_t)strlen(text);
}

/* Paths live in a small table; a handle is its slot's index plus one. */
#define GEO_MAX_PATHS 64

typedef struct geo_path_data {
	int used;
	geo_point *points;
	size_t count;
} geo_path_data;

static geo_path_data paths[GEO_MAX_PATHS];

static geo_path_data *geo_path_find(geo_path path) {
	if (path == 0 || path > GEO_MAX_PATHS || !paths[path - 1].used)
		return NULL;
	return &paths[path - 1];
}

geo_path geo_path_create(void) {
	for (uint32_t index = 0; index < GEO_MAX_PATHS; index++) {
		if (!paths[index].used) {
			paths[index].used = 1;
			return index + 1;
		}
	}
	return 0;
}

void geo_path_add(geo_path path, const geo_point *point) {
	geo_path_data *data = geo_path_find(path);
	if (data == NULL)
		return;
	geo_point *grown = realloc(data->points, (data->count + 1) * sizeof(geo_point));
	if (grown == NULL)
		return;
	data->points = grown;
	data->points[data->count++] = *point;
}

double geo_path_length(geo_path path) {
	geo_path_data *data = geo_path_find(path);
	double length = 0;
	if (data == NULL)
		return 0;
	for (size_t index = 1; index < data->count; index++)
		length += geo_distance(&data->points[index - 1], &data->points[index]);
	return length;
}

void geo_path_destroy(geo_path path) {
	geo_path_data *data = geo_path_find(path);
	if (data == NULL)
		return;
	free(data->points);
	memset(data, 0, sizeof(*data));
}
