@vs fixture_vs
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(std140, binding=0) uniform vs_params {
    float shift;
    vec4 weights[2];
};
out vec2 texcoord;
void main() {
    gl_Position = vec4(position, 0.0, 1.0) + vec4(shift) + weights[0] + weights[1];
    texcoord = uv;
}
@end

@fs fixture_fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 texcoord;
out vec4 color;
void main() {
    color = texture(sampler2D(tex, smp), texcoord);
#ifdef PREVIEW
    color.rgb *= 0.5;
#endif
}
@end

@program fixture fixture_vs fixture_fs
