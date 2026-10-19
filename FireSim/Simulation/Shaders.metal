#include <metal_stdlib>
#include "SimTypes.h"
using namespace metal;

// MARK: - Helpers

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler displaySampler(coord::normalized, address::clamp_to_edge, filter::linear);

inline bool inBounds(uint2 g, uint2 size) { return g.x < size.x && g.y < size.y; }

inline bool outside(int2 c, uint2 size) {
    return c.x < 0 || c.y < 0 || c.x >= int(size.x) || c.y >= int(size.y);
}

/// Cell types: 0 fluid, 1 wall, 2 door closed, 3 door open, 4 window closed, 5 window open (vent to ambient)
inline uint cellType(texture2d<uint, access::read> obst, int2 c, uint2 size) {
    if (outside(c, size)) return 1; // the domain boundary is a wall
    return obst.read(uint2(c)).r;
}
inline bool isSolid(uint t) { return t == 1 || t == 2 || t == 4; }
inline bool isVent(uint t)  { return t == 5; }

inline float2 readVel(texture2d<float, access::read> tex, int2 c, uint2 size) {
    if (outside(c, size)) return float2(0.0);
    return tex.read(uint2(c)).rg;
}
inline float readScalar(texture2d<float, access::read> tex, int2 c, uint2 size, float fallback) {
    if (outside(c, size)) return fallback;
    return tex.read(uint2(c)).r;
}

// MARK: - Clear

kernel void clearFields(texture2d<float, access::write> velocity    [[texture(0)]],
                        texture2d<float, access::write> temperature [[texture(1)]],
                        texture2d<float, access::write> smoke       [[texture(2)]],
                        texture2d<float, access::write> co          [[texture(3)]],
                        texture2d<float, access::write> pressure    [[texture(4)]],
                        constant SimParams& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    velocity.write(float4(0.0), gid);
    temperature.write(float4(p.ambientTemp), gid);
    smoke.write(float4(0.0), gid);
    co.write(float4(0.0), gid);
    pressure.write(float4(0.0), gid);
}

// MARK: - Sources, buoyancy, cooling

kernel void applyForcesAndSources(texture2d<float, access::read>  velIn   [[texture(0)]],
                                  texture2d<float, access::read>  tempIn  [[texture(1)]],
                                  texture2d<float, access::read>  smokeIn [[texture(2)]],
                                  texture2d<float, access::read>  coIn    [[texture(3)]],
                                  texture2d<uint,  access::read>  obst    [[texture(4)]],
                                  texture2d<float, access::write> velOut  [[texture(5)]],
                                  texture2d<float, access::write> tempOut [[texture(6)]],
                                  texture2d<float, access::write> smokeOut[[texture(7)]],
                                  texture2d<float, access::write> coOut   [[texture(8)]],
                                  constant SimParams& p [[buffer(0)]],
                                  constant FireSourceGPU* sources [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    uint t = obst.read(gid).r;
    if (isSolid(t)) {
        velOut.write(float4(0.0), gid);
        tempOut.write(float4(p.ambientTemp), gid);
        smokeOut.write(float4(0.0), gid);
        coOut.write(float4(0.0), gid);
        return;
    }

    float  T = tempIn.read(gid).r;
    float  s = smokeIn.read(gid).r;
    float  c = coIn.read(gid).r;
    float2 v = velIn.read(gid).rg;

    if (isVent(t)) {
        // Open window: fixed ambient boundary. Flow may pass through freely.
        velOut.write(float4(v, 0.0, 0.0), gid);
        tempOut.write(float4(p.ambientTemp), gid);
        smokeOut.write(float4(0.0), gid);
        coOut.write(float4(0.0), gid);
        return;
    }

    float cellArea   = p.dx * p.dx;               // m^2
    float cellVolume = cellArea * p.cellDepth;    // m^3
    float2 pos = float2(gid) + 0.5;

    for (uint i = 0; i < p.sourceCount; i++) {
        FireSourceGPU src = sources[i];
        float d = distance(pos, src.position);
        if (d <= src.radius) {
            float areaM2 = M_PI_F * src.radius * src.radius * cellArea;
            float frac   = cellArea / max(areaM2, cellArea);     // fraction of the source in this cell
            float heatKW = src.heatRelease * frac;               // kW into this cell
            T += heatKW / (p.rhoCp * cellVolume) * p.dt;         // kW / (kJ/(m^3 K) * m^3) = K/s
            s += src.sootRate * frac / cellVolume * p.dt;        // kg/m^3
            c += src.coRate   * frac / cellVolume * p.dt;        // kg/m^3

            if (p.planMode == 1) {
                // Top-down view: model thermal expansion as a radial push from the fire.
                float2 dir = (d > 1e-3) ? (pos - src.position) / d : float2(0.0);
                float push = p.expansion * (src.heatRelease / 1000.0);
                v += dir * push * p.dt;
            }
        }
    }

    T = min(T, 1400.0f);
    // Relaxation toward ambient: proxy for radiative loss + heat transfer to walls.
    T += (p.ambientTemp - T) * p.coolingRate * p.dt;

    if (p.planMode == 0) {
        // Boussinesq buoyancy, screen-up is -y.
        float a = p.gravity * (T - p.ambientTemp) / p.ambientTemp * p.buoyancy;
        v.y -= a * p.dt;
    }

    float speed = length(v);
    const float maxSpeed = 12.0;
    if (speed > maxSpeed) v *= maxSpeed / speed;

    velOut.write(float4(v, 0.0, 0.0), gid);
    tempOut.write(float4(T), gid);
    smokeOut.write(float4(max(s, 0.0f)), gid);
    coOut.write(float4(max(c, 0.0f)), gid);
}

// MARK: - Vorticity confinement

kernel void computeCurl(texture2d<float, access::read>  vel  [[texture(0)]],
                        texture2d<uint,  access::read>  obst [[texture(1)]],
                        texture2d<float, access::write> curl [[texture(2)]],
                        constant SimParams& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    int2 c = int2(gid);
    float2 vL = readVel(vel, c + int2(-1, 0), p.gridSize);
    float2 vR = readVel(vel, c + int2( 1, 0), p.gridSize);
    float2 vU = readVel(vel, c + int2( 0,-1), p.gridSize);
    float2 vD = readVel(vel, c + int2( 0, 1), p.gridSize);
    float w = ((vR.y - vL.y) - (vD.x - vU.x)) / (2.0 * p.dx);
    curl.write(float4(w), gid);
}

kernel void applyVorticity(texture2d<float, access::read>  velIn  [[texture(0)]],
                           texture2d<float, access::read>  curl   [[texture(1)]],
                           texture2d<uint,  access::read>  obst   [[texture(2)]],
                           texture2d<float, access::write> velOut [[texture(3)]],
                           constant SimParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    if (isSolid(obst.read(gid).r)) { velOut.write(float4(0.0), gid); return; }
    int2 c = int2(gid);
    float wL = abs(readScalar(curl, c + int2(-1, 0), p.gridSize, 0.0));
    float wR = abs(readScalar(curl, c + int2( 1, 0), p.gridSize, 0.0));
    float wU = abs(readScalar(curl, c + int2( 0,-1), p.gridSize, 0.0));
    float wD = abs(readScalar(curl, c + int2( 0, 1), p.gridSize, 0.0));
    float w  = curl.read(gid).r;
    float2 grad = float2(wR - wL, wD - wU) * 0.5;
    float2 N = grad / (length(grad) + 1e-5);
    float2 force = p.vorticity * p.dx * float2(N.y, -N.x) * w;
    float2 v = velIn.read(gid).rg + force * p.dt;
    velOut.write(float4(v, 0.0, 0.0), gid);
}

// MARK: - Advection (semi-Lagrangian)

kernel void advectVelocity(texture2d<float, access::sample> velIn  [[texture(0)]],
                           texture2d<uint,  access::read>   obst   [[texture(1)]],
                           texture2d<float, access::write>  velOut [[texture(2)]],
                           constant SimParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    if (isSolid(obst.read(gid).r)) { velOut.write(float4(0.0), gid); return; }
    float2 v = velIn.read(gid).rg;
    float2 back = (float2(gid) + 0.5) - p.dt * v / p.dx;
    float2 uv = back / float2(p.gridSize);
    float2 nv = velIn.sample(linearSampler, uv).rg * p.velocityDissipation;
    velOut.write(float4(nv, 0.0, 0.0), gid);
}

kernel void advectScalar(texture2d<float, access::sample> scalarIn  [[texture(0)]],
                         texture2d<float, access::read>   vel       [[texture(1)]],
                         texture2d<uint,  access::read>   obst      [[texture(2)]],
                         texture2d<float, access::write>  scalarOut [[texture(3)]],
                         constant SimParams& p [[buffer(0)]],
                         constant ScalarAdvectParams& sp [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    uint t = obst.read(gid).r;
    if (isSolid(t) || isVent(t)) { scalarOut.write(float4(sp.ambient), gid); return; }
    float2 v = vel.read(gid).rg;
    float2 back = (float2(gid) + 0.5) - p.dt * v / p.dx;
    float2 uv = back / float2(p.gridSize);
    float value = scalarIn.sample(linearSampler, uv).r;
    value = sp.ambient + (value - sp.ambient) * sp.dissipation;
    scalarOut.write(float4(value), gid);
}

// MARK: - Pressure projection

kernel void computeDivergence(texture2d<float, access::read>  vel  [[texture(0)]],
                              texture2d<uint,  access::read>  obst [[texture(1)]],
                              texture2d<float, access::write> div  [[texture(2)]],
                              constant SimParams& p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    int2 c = int2(gid);
    float2 vL = readVel(vel, c + int2(-1, 0), p.gridSize);
    float2 vR = readVel(vel, c + int2( 1, 0), p.gridSize);
    float2 vU = readVel(vel, c + int2( 0,-1), p.gridSize);
    float2 vD = readVel(vel, c + int2( 0, 1), p.gridSize);
    float d = ((vR.x - vL.x) + (vD.y - vU.y)) / (2.0 * p.dx);
    div.write(float4(d), gid);
}

kernel void jacobi(texture2d<float, access::read>  pIn  [[texture(0)]],
                   texture2d<float, access::read>  div  [[texture(1)]],
                   texture2d<uint,  access::read>  obst [[texture(2)]],
                   texture2d<float, access::write> pOut [[texture(3)]],
                   constant SimParams& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    uint t = obst.read(gid).r;
    if (isVent(t)) { pOut.write(float4(0.0), gid); return; } // Dirichlet: open to ambient
    int2 c = int2(gid);
    float pc = pIn.read(gid).r;
    int2 offs[4] = { int2(-1,0), int2(1,0), int2(0,-1), int2(0,1) };
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        int2 n = c + offs[i];
        uint nt = cellType(obst, n, p.gridSize);
        if (isSolid(nt)) sum += pc;                       // Neumann at walls
        else if (isVent(nt)) sum += 0.0;
        else sum += pIn.read(uint2(n)).r;
    }
    float d = div.read(gid).r;
    float pn = (sum - p.dx * p.dx * d) * 0.25;
    pOut.write(float4(pn), gid);
}

kernel void subtractGradient(texture2d<float, access::read>  velIn    [[texture(0)]],
                             texture2d<float, access::read>  pressure [[texture(1)]],
                             texture2d<uint,  access::read>  obst     [[texture(2)]],
                             texture2d<float, access::write> velOut   [[texture(3)]],
                             constant SimParams& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    uint t = obst.read(gid).r;
    if (isSolid(t)) { velOut.write(float4(0.0), gid); return; }
    int2 c = int2(gid);
    float pc = pressure.read(gid).r;
    uint tL = cellType(obst, c + int2(-1,0), p.gridSize);
    uint tR = cellType(obst, c + int2( 1,0), p.gridSize);
    uint tU = cellType(obst, c + int2(0,-1), p.gridSize);
    uint tD = cellType(obst, c + int2(0, 1), p.gridSize);
    float pL = isSolid(tL) ? pc : (isVent(tL) ? 0.0 : pressure.read(uint2(c + int2(-1,0))).r);
    float pR = isSolid(tR) ? pc : (isVent(tR) ? 0.0 : pressure.read(uint2(c + int2( 1,0))).r);
    float pU = isSolid(tU) ? pc : (isVent(tU) ? 0.0 : pressure.read(uint2(c + int2(0,-1))).r);
    float pD = isSolid(tD) ? pc : (isVent(tD) ? 0.0 : pressure.read(uint2(c + int2(0, 1))).r);
    float2 v = velIn.read(gid).rg;
    v -= float2(pR - pL, pD - pU) / (2.0 * p.dx);
    // No-penetration at walls
    if ((isSolid(tL) && v.x < 0.0) || (isSolid(tR) && v.x > 0.0)) v.x = 0.0;
    if ((isSolid(tU) && v.y < 0.0) || (isSolid(tD) && v.y > 0.0)) v.y = 0.0;
    velOut.write(float4(v, 0.0, 0.0), gid);
}

// MARK: - Rendering

inline float3 heatRamp(float u) {
    // dark blue -> cyan -> yellow -> red -> white
    u = clamp(u, 0.0f, 1.0f);
    float3 c0 = float3(0.05, 0.10, 0.40);
    float3 c1 = float3(0.00, 0.75, 0.90);
    float3 c2 = float3(1.00, 0.90, 0.20);
    float3 c3 = float3(0.95, 0.15, 0.05);
    float3 c4 = float3(1.00, 1.00, 1.00);
    if (u < 0.25) return mix(c0, c1, u / 0.25);
    if (u < 0.50) return mix(c1, c2, (u - 0.25) / 0.25);
    if (u < 0.75) return mix(c2, c3, (u - 0.50) / 0.25);
    return mix(c3, c4, (u - 0.75) / 0.25);
}

inline float3 tenabilityRamp(float u) {
    // 0 = untenable (red), 1 = fine (green)
    u = clamp(u, 0.0f, 1.0f);
    float3 red = float3(0.85, 0.15, 0.10), orange = float3(0.95, 0.55, 0.10);
    float3 yellow = float3(0.95, 0.90, 0.25), green = float3(0.30, 0.75, 0.35);
    if (u < 0.33) return mix(red, orange, u / 0.33);
    if (u < 0.66) return mix(orange, yellow, (u - 0.33) / 0.33);
    return mix(yellow, green, (u - 0.66) / 0.34);
}

kernel void renderOutput(texture2d<float, access::read>  temp  [[texture(0)]],
                         texture2d<float, access::read>  smoke [[texture(1)]],
                         texture2d<float, access::read>  co    [[texture(2)]],
                         texture2d<float, access::read>  vel   [[texture(3)]],
                         texture2d<uint,  access::read>  obst  [[texture(4)]],
                         texture2d<float, access::write> out   [[texture(5)]],
                         constant SimParams& p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (!inBounds(gid, p.gridSize)) return;
    uint t = obst.read(gid).r;
    float3 color;
    if      (t == 1) color = float3(0.18, 0.18, 0.21);
    else if (t == 2) color = float3(0.55, 0.35, 0.15);
    else if (t == 3) color = float3(0.88, 0.70, 0.40);
    else if (t == 4) color = float3(0.25, 0.45, 0.78);
    else if (t == 5) color = float3(0.55, 0.88, 1.00);
    else {
        float T = temp.read(gid).r;
        float s = smoke.read(gid).r;
        float c = co.read(gid).r;
        float3 bg = float3(0.965, 0.955, 0.935);
        switch (p.displayMode) {
            case 1: { // temperature
                float u = (T - p.ambientTemp) / 600.0;
                color = mix(bg, heatRamp(u), clamp(u * 4.0, 0.08f, 1.0f));
                break;
            }
            case 2: { // CO ppm
                float ppm = c / 1.2 * 1.0357e6;
                float u = clamp(log10(max(ppm, 1.0f)) / 4.0, 0.0f, 1.0f); // 1 ppm..10000 ppm
                color = mix(bg, tenabilityRamp(1.0 - u), clamp(u * 2.0, 0.0f, 1.0f));
                break;
            }
            case 3: { // visibility, Jin: S = C / K, K = Km * Cs
                float K = 8700.0 * s;
                float S = (K > 1e-4) ? 3.0 / K : 30.0;
                float u = clamp(S / 15.0, 0.0f, 1.0f);
                color = mix(bg, tenabilityRamp(u), 0.9);
                break;
            }
            default: { // smoke + fire glow
                float K = 8700.0 * s;
                float optical = 1.0 - exp(-K * p.cellDepth * 0.35);
                float3 smokeColor = float3(0.24, 0.23, 0.22);
                color = mix(bg, smokeColor, clamp(optical, 0.0f, 0.95f));
                float hot = clamp((T - p.ambientTemp) / 500.0, 0.0f, 1.0f);
                float3 fire = mix(float3(1.0, 0.35, 0.05), float3(1.0, 0.95, 0.60), hot * hot);
                color = mix(color, fire, hot);
                break;
            }
        }
    }
    out.write(float4(color, 1.0), gid);
}

// MARK: - Fullscreen blit to the drawable

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.pos = float4(pos[vid], 0.0, 1.0);
    o.uv = float2((pos[vid].x + 1.0) * 0.5, 1.0 - (pos[vid].y + 1.0) * 0.5);
    return o;
}

fragment float4 blitFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return tex.sample(displaySampler, in.uv);
}
