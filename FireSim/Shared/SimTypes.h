#ifndef SimTypes_h
#define SimTypes_h

#include <simd/simd.h>

/// Parameters shared between Swift and Metal. Keep layouts identical.
typedef struct {
    simd_uint2 gridSize;        // cells (width, height)
    float dx;                   // meters per cell
    float dt;                   // seconds per substep
    float ambientTemp;          // Kelvin
    float gravity;              // m/s^2
    float buoyancy;             // Boussinesq scale (1.0 = physical)
    float vorticity;            // vorticity confinement strength
    float coolingRate;          // 1/s, relaxation toward ambient (radiative + wall loss proxy)
    float smokeDissipation;     // per-substep multiplier (1.0 = conservative)
    float velocityDissipation;  // per-substep multiplier
    float rhoCp;                // kJ/(m^3 K) for air (~1.2)
    float cellDepth;            // slab depth of the 2D domain, meters
    float expansion;            // thermal expansion push used in plan (top-down) mode
    uint32_t sourceCount;
    uint32_t planMode;          // 0 = cross-section (buoyancy in-plane), 1 = top-down plan
    uint32_t displayMode;       // 0 smoke, 1 temperature, 2 CO, 3 visibility
} SimParams;

typedef struct {
    simd_float2 position;       // grid cells
    float radius;               // grid cells
    float heatRelease;          // kW (total HRR of this source)
    float sootRate;             // kg/s soot produced
    float coRate;               // kg/s CO produced
} FireSourceGPU;

typedef struct {
    float dissipation;          // per-substep multiplier
    float ambient;              // value scalar relaxes toward (ambient temp, or 0)
} ScalarAdvectParams;

#endif /* SimTypes_h */
