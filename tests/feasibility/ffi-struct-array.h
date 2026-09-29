#include <stdint.h>

#define HXI_OUT_ARRAY(count) __attribute__((annotate("hxi:out_array")))
#define HXI_INOUT __attribute__((annotate("hxi:inout")))

typedef struct hxi_probe_point {
  double x;
  double y;
} hxi_probe_point;

int32_t hxi_probe_read_points(hxi_probe_point *points HXI_OUT_ARRAY(count),
                              uint32_t *count HXI_INOUT);
