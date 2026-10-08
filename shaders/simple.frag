#version 460 core

uniform sampler2D shadowTex;

in vec4 vColor;
in vec2 vUv;
out vec4 fragColor;

void main() {
    // Sample the pre-pass depth texture (or the 1x1 "far" map) so the pass
    // reads a render-to-texture result, as the real renderer does.
    float d = texture(shadowTex, vUv).r;
    fragColor = vec4(vColor.rgb * (0.6 + 0.4 * d), vColor.a);
}
