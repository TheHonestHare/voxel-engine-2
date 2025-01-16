struct FragmentIn {
    @location(0) uv: vec2f,
}

@fragment fn main(in: FragmentIn) -> @location(0) vec4f {
    return vec4f(in.uv, 0, 1);
}