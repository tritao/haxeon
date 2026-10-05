// Canonical NativeKit UI effect shaders.

@vs effect_vs
layout(binding=0) uniform effect_vs_params {
    vec4 value;
};
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv0;
layout(location=0) out vec2 uv;
void main() {
    uv = uv0;
    gl_Position = vec4(((position.x / value.x) * 2.0) - 1.0,
                       1.0 - ((position.y / value.y) * 2.0), 0.0, 1.0);
}
@end

@fs effect_fs
layout(binding=1) uniform effect_fs_params {
    vec4 value[5];
};
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 frag_color;
void main() {
    vec4 source = texture(sampler2D(tex, smp), uv);
    frag_color = vec4(dot(source, value[0]) + value[4].x,
                      dot(source, value[1]) + value[4].y,
                      dot(source, value[2]) + value[4].z,
                      dot(source, value[3]) + value[4].w);
}
@end

@program effect effect_vs effect_fs

@vs blur_vs
layout(binding=0) uniform blur_vs_params {
    vec4 value;
};
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv0;
layout(location=0) out vec2 uv;
void main() {
    uv = uv0;
    gl_Position = vec4(((position.x / value.x) * 2.0) - 1.0,
                       1.0 - ((position.y / value.y) * 2.0), 0.0, 1.0);
}
@end

@fs blur_fs
layout(binding=1) uniform blur_fs_params {
    vec4 value;
};
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 frag_color;
void main() {
    vec4 source = texture(sampler2D(tex, smp), uv);
    float sigma = value.x;
    if (sigma <= 0.0001) {
        frag_color = source;
        return;
    }
    vec2 direction = value.y > 0.5 ? vec2(0.0, value.w) : vec2(value.z, 0.0);
    // Sample symmetrically at half-step intervals so linear filtering fills
    // the interval between neighboring Gaussian samples. Six pairs provide
    // a smooth 13-tap effective kernel while keeping the pass separable and
    // bounded on every backend.
    float sample_step = max(1.0, sigma * 0.5);
    vec4 result = source;
    float weight_sum = 1.0;
    for (int index = 1; index <= 6; index++) {
        float offset_in_texels = (float(index) - 0.5) * sample_step;
        float normalized = offset_in_texels / sigma;
        float weight = exp(-0.5 * normalized * normalized);
        vec2 offset = direction * offset_in_texels;
        result += (texture(sampler2D(tex, smp), uv + offset) +
                   texture(sampler2D(tex, smp), uv - offset)) * weight;
        weight_sum += 2.0 * weight;
    }
    frag_color = result / weight_sum;
}
@end

@program blur blur_vs blur_fs

@vs drop_shadow_vs
layout(binding=0) uniform drop_shadow_vs_params {
    vec4 value;
};
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv0;
layout(location=0) out vec2 uv;
void main() {
    uv = uv0;
    gl_Position = vec4(((position.x / value.x) * 2.0) - 1.0,
                       1.0 - ((position.y / value.y) * 2.0), 0.0, 1.0);
}
@end

@fs drop_shadow_fs
layout(binding=1) uniform drop_shadow_fs_params {
    vec4 value[3];
};
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 frag_color;

// Pixels outside the source are transparent. Clamp-to-edge sampling would
// smear content touching the target edge into the shadow, which happens when
// the offset is at least the blur extent and leaves no margin on that side.
float source_alpha(vec2 point) {
    vec2 inside = step(vec2(0.0), point) * step(point, vec2(1.0));
    return texture(sampler2D(tex, smp), point).a * inside.x * inside.y;
}

void main() {
    vec4 parameters = value[0];
    vec4 color = value[1];
    vec2 texel = value[2].xy;
    vec2 center = uv;
    // Effect passes sample with v running bottom-up (v = 1 at the target's top
    // edge), so a positive screen-space Y offset reads from a higher v.
    if (parameters.y > 0.5)
        center -= vec2(parameters.z * texel.x, -parameters.w * texel.y);
    float alpha = source_alpha(center);
    float weight_sum = 1.0;
    if (parameters.x > 0.0001) {
        float sample_step = max(1.0, parameters.x * 0.5);
        vec2 direction = parameters.y > 0.5 ? vec2(0.0, texel.y) : vec2(texel.x, 0.0);
        for (int index = 1; index <= 6; index++) {
            float offset_in_texels = (float(index) - 0.5) * sample_step;
            float normalized = offset_in_texels / parameters.x;
            float weight = exp(-0.5 * normalized * normalized);
            vec2 offset = direction * offset_in_texels;
            alpha += (source_alpha(center + offset) + source_alpha(center - offset)) * weight;
            weight_sum += 2.0 * weight;
        }
    }
    alpha /= weight_sum;
    if (parameters.y <= 0.5)
        frag_color = vec4(0.0, 0.0, 0.0, alpha);
    else
        frag_color = vec4(color.rgb * color.a * alpha, color.a * alpha);
}
@end

@program drop_shadow drop_shadow_vs drop_shadow_fs

@vs box_shadow_vs
layout(binding=0) uniform box_shadow_vs_params {
    vec4 value;
};
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv0;
layout(location=0) out vec2 uv;
void main() {
    uv = uv0;
    gl_Position = vec4(((position.x / value.x) * 2.0) - 1.0,
                       1.0 - ((position.y / value.y) * 2.0), 0.0, 1.0);
}
@end

@fs box_shadow_fs
layout(binding=1) uniform box_shadow_fs_params {
    vec4 value[4];
};
layout(location=0) in vec2 uv;
layout(location=0) out vec4 frag_color;

// Closed-form Gaussian-blurred rounded rectangle: exact erf integral across X,
// a short Gaussian-weighted quadrature across Y. Matches CSS box-shadow falloff
// (half intensity at the shape edge) without rendering an offscreen mask.
vec2 erf_approx(vec2 x) {
    vec2 s = sign(x);
    vec2 a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.50662827463 * sigma);
}

float shadow_row(float x, float y, float sigma, float corner, vec2 half_extent) {
    float delta = min(half_extent.y - corner - abs(y), 0.0);
    float curved = half_extent.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf_approx((x + vec2(-curved, curved)) * (0.70710678 / sigma));
    return integral.y - integral.x;
}

float rounded_rect_distance(vec2 local, vec2 half_extent, float radius) {
    vec2 q = abs(local) - (half_extent - vec2(radius));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// CSS spread adjustment: sharp corners stay sharp, small radii grow smoothly.
vec4 spread_radii(vec4 radii, float spread) {
    if (spread <= 0.0)
        return max(radii + vec4(spread), vec4(0.0));
    vec4 ratio = radii / spread - vec4(1.0);
    vec4 small = radii + vec4(spread) * (vec4(1.0) + ratio * ratio * ratio);
    vec4 grown = mix(small, radii + vec4(spread), step(vec4(spread), radii));
    return mix(vec4(0.0), grown, step(vec4(0.0001), radii));
}

void main() {
    vec4 base = value[0];
    vec4 params = value[1];
    vec4 color = value[3];
    vec2 size = base.zw + vec2(2.0 * params.w);
    vec2 half_extent = size * 0.5;
    vec2 center = base.xy + vec2(params.x, params.y) + base.zw * 0.5;
    vec2 local = uv - center;
    vec4 radii = spread_radii(value[2], params.w);
    float corner = local.x < 0.0 ? (local.y < 0.0 ? radii.x : radii.w)
                                 : (local.y < 0.0 ? radii.y : radii.z);
    corner = max(0.0, min(corner, min(half_extent.x, half_extent.y)));
    float sigma = params.z;
    float alpha;
    if (sigma <= 0.0001) {
        alpha = clamp(0.5 - rounded_rect_distance(local, half_extent, corner), 0.0, 1.0);
    } else {
        float low = local.y - half_extent.y;
        float high = local.y + half_extent.y;
        float start = clamp(-3.0 * sigma, low, high);
        float finish = clamp(3.0 * sigma, low, high);
        float step_size = (finish - start) / 4.0;
        float y = start + step_size * 0.5;
        alpha = 0.0;
        for (int index = 0; index < 4; index++) {
            alpha += shadow_row(local.x, local.y - y, sigma, corner, half_extent) *
                     gaussian(y, sigma) * step_size;
            y += step_size;
        }
    }
    // Outer shadows are clipped to outside the casting box, like CSS, so they
    // never show through translucent surfaces or where a surface is missing.
    vec2 box_half = base.zw * 0.5;
    vec2 box_local = uv - (base.xy + box_half);
    vec4 box_radii = value[2];
    float box_corner = box_local.x < 0.0 ? (box_local.y < 0.0 ? box_radii.x : box_radii.w)
                                         : (box_local.y < 0.0 ? box_radii.y : box_radii.z);
    box_corner = max(0.0, min(box_corner, min(box_half.x, box_half.y)));
    alpha *= clamp(rounded_rect_distance(box_local, box_half, box_corner) + 0.5, 0.0, 1.0);
    frag_color = vec4(color.rgb * color.a * alpha, color.a * alpha);
}
@end

@program box_shadow box_shadow_vs box_shadow_fs

@vs mask_vs
layout(binding=0) uniform mask_vs_params {
    vec4 value;
};
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv0;
layout(location=0) out vec2 uv;
void main() {
    uv = uv0;
    gl_Position = vec4(((position.x / value.x) * 2.0) - 1.0,
                       1.0 - ((position.y / value.y) * 2.0), 0.0, 1.0);
}
@end

@fs mask_fs
layout(binding=1) uniform mask_fs_params {
    vec4 value[3];
};
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(binding=1) uniform texture2D mask_tex;
layout(binding=1) uniform sampler mask_smp;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 frag_color;
void main() {
    vec4 source = texture(sampler2D(tex, smp), uv);
    float kind = value[0].x;
    float mask_alpha = 1.0;
    if (kind > 4.5) {
        mask_alpha = texture(sampler2D(mask_tex, mask_smp), uv).a;
    } else if (kind > 3.5) {
        vec2 direction = value[1].xy - value[0].zw;
        float denominator = max(dot(direction, direction), 0.000001);
        float amount = clamp(dot(uv - value[0].zw, direction) / denominator, 0.0, 1.0);
        mask_alpha = mix(value[1].z, value[1].w, amount);
    } else if (kind > 2.5) {
        vec2 position = uv * value[2].xy - value[2].xy * 0.5;
        mask_alpha = step(length(position), value[0].y);
    } else if (kind > 1.5) {
        vec2 position = uv * value[2].xy - value[2].xy * 0.5;
        vec2 extent = value[2].xy * 0.5 - vec2(value[0].y);
        vec2 q = abs(position) - extent;
        float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - value[0].y;
        mask_alpha = step(distance, 0.0);
    }
    frag_color = vec4(source.rgb * mask_alpha, source.a * mask_alpha);
}
@end

@program mask mask_vs mask_fs
