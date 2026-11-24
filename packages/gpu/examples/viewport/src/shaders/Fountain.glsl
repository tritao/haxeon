@block particle
struct particle {
    vec2 position;
    vec2 velocity;
};
@end

@cs step_cs
@include_block particle
layout(local_size_x=64) in;

layout(binding=0) buffer particles {
    particle items[];
};

layout(std140, binding=0) uniform step_params {
    float dt;
    float time;
    float gravity;
    float spread;
    float reset;
};

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

// A particle launched from the spout `age` seconds ago.
particle launch(float seed, float age) {
    vec2 velocity = vec2((hash(seed) - 0.5) * spread, 1.7 + 0.4 * hash(seed + 1.0));
    particle p;
    p.position = vec2(0.0, -0.95) + velocity * age - vec2(0.0, 0.5 * gravity * age * age);
    p.velocity = velocity - vec2(0.0, gravity * age);
    return p;
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    particle p = items[index];
    float seed = float(index) * 0.618 + time;
    if (reset > 0.5 || p.velocity == vec2(0.0)) {
        p = launch(seed, 2.4 * hash(float(index)));
    } else if (p.position.y < -1.0) {
        p = launch(seed, 0.0);
    }
    p.velocity.y -= gravity * dt;
    p.position += p.velocity * dt;
    items[index] = p;
}
@end

@vs draw_vs
@include_block particle

layout(binding=0) readonly buffer drawn {
    particle items[];
};

layout(std140, binding=0) uniform draw_params {
    float warm;
};

out vec3 color;

void main() {
    const vec2 corners[6] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
        vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
    particle p = items[gl_InstanceIndex];
    gl_Position = vec4(p.position + corners[gl_VertexIndex] * 0.007, 0.0, 1.0);
    float speed = clamp(length(p.velocity) / 1.8, 0.0, 1.0);
    vec3 slow = mix(vec3(0.33, 0.93, 0.76), vec3(1.0, 0.82, 0.36), warm);
    vec3 fast = mix(vec3(1.0, 0.42, 0.56), vec3(0.94, 0.33, 0.18), warm);
    color = mix(slow, fast, speed);
}
@end

@fs draw_fs
in vec3 color;
out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
@end

@program step step_cs
@program draw draw_vs draw_fs
