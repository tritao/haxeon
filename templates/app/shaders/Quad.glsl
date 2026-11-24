@vs quad_vs
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(std140, binding=0) uniform vs_params {
    mat4 transform;
};
out vec2 texcoord;

void main() {
    gl_Position = transform * vec4(position, 0.0, 1.0);
    texcoord = uv;
}
@end

@fs quad_fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 texcoord;
layout(location=0) out vec4 color;

void main() {
    color = texture(sampler2D(tex, smp), texcoord);
#ifdef PREVIEW
    color.rgb *= 0.5;
#endif
}
@end

@program quad quad_vs quad_fs
