# FireSim — 2D 화재·연기 유체 시뮬레이터 (Swift + Metal)

iOS 17 / macOS 14. 실시간 인터랙티브 모드와 고해상도 오프라인 모드를 가진 2D 화재 시뮬레이터입니다.

## 빌드

```bash
brew install xcodegen
cd FireSim
xcodegen generate
open FireSim.xcodeproj
```

`FireSim_macOS` 또는 `FireSim_iOS` 스킴을 선택해 실행합니다. Metal을 쓰므로 iOS 시뮬레이터보다 실기기(또는 Mac) 실행을 권장합니다.
XcodeGen 없이 쓰려면 Xcode에서 Multiplatform App을 만들고 `FireSim/` 폴더를 끌어다 넣은 뒤,
Build Settings에서 `Objective-C Bridging Header = FireSim/Shared/FireSim-Bridging-Header.h`,
`Metal Compiler – Header Search Paths = $(SRCROOT)/FireSim/Shared` 두 가지만 잡아주면 됩니다.

## 구조

```
FireSim/
├── App/FireSimApp.swift
├── Shared/SimTypes.h                 # Swift ↔ Metal 공유 구조체 (SimParams, FireSourceGPU)
├── Model/FloorPlan.swift             # 벽/문/창, 발화점(t² 성장), 센서, 프리셋, 래스터라이즈
├── Simulation/Shaders.metal          # 유체 솔버 컴퓨트 커널 + 렌더 커널
├── Simulation/FluidSimulator.swift   # Metal 파이프라인, 핑퐁 텍스처, 스텝/렌더/리드백
├── Simulation/SimulationController.swift  # 프레임 루프, 편집, 센서 기록, 오프라인 실행, CSV
└── Views/                            # SwiftUI: 캔버스(편집 제스처), 컨트롤 패널, Swift Charts
```

## 물리 모델 (무엇이 정확하고 무엇이 근사인지)

**유체 솔버** — Stam의 Stable Fluids(반라그랑지안 이류 + Jacobi 압력 투영 + 와도 보존)를 GPU에서 돕니다.
비압축 가정이므로 **열팽창에 의한 압력 상승·플래시오버·화염 자체의 연소 화학은 모델링하지 않습니다.**
이 선택은 "실시간 + 하이브리드"에 맞춘 것이고, 공학 검토용 수치(NIST FDS 수준)를 대체하지 않습니다.

**정량적으로 넣은 것**
- 화재 성장: NFPA 92 t² 곡선 (`Q = α t²`, slow/medium/fast/ultrafast α = 0.00293 / 0.01172 / 0.0469 / 0.1876 kW/s²), 최대 HRR에서 포화
- 연료 소비: `ṁ = Q / ΔHc` (기본 ΔHc = 20 MJ/kg), 그을음 수율 0.1, CO 수율 0.04 kg/kg (연소 중 폴리우레탄 계열 값)
- 온도: 셀당 `dT/dt = Q_cell / (ρ·cp·V)` (ρcp ≈ 1.2 kJ/m³K), 1400 K 상한, 주변으로의 완화 냉각(복사·벽 손실 대용)
- 부력: Boussinesq `a = g (T − T₀)/T₀`
- 가시거리: Jin 관계식 `S = C / (Km · Cs)`, Km = 8700 m²/kg, C = 3 (반사형 표지)
- CO 농도: 질량농도 → ppm 변환 (`C/ρ_air × 29/28 × 10⁶`)
- 경계: 벽 = 무투과(Neumann 압력), 열린 창 = 외기 경계(Dirichlet 압력 0, 스칼라 리셋), 열린 문 = 유체 셀

**근사**
- 2D 슬랩 깊이 1 m 가정 (`cellDepth`). 3D 희석이 없어 농도가 실제보다 보수적(높게) 나옵니다.
- 평면(위에서 보기) 모드에서는 부력이 평면 밖 방향이라 **열팽창 반경 방향 밀어냄**으로 근사합니다. 연기 확산 경로의 정성적 관찰용입니다.
- 단면 모드가 물리적으로 더 의미 있습니다(연기층 형성, 천장 제트, 개구부 배연).
- 한계값(60 °C, 가시거리 5 m, CO 1200 ppm)은 경험칙이며 노출 시간을 고려하는 FED 계산은 포함하지 않았습니다.

## 하이브리드 모드

- **실시간**: 192×N 격자, 120 Hz 서브스텝, Jacobi 40회, 60 fps. 편집하면서 바로 반응을 봅니다.
- **오프라인**: 512(또는 384/768) 격자, 240 Hz 서브스텝, Jacobi 80회로 지정 시간만큼 계산한 뒤 0.25 s 간격 프레임을 재생합니다.
  프레임은 CGImage로 메모리에 보관되므로 512×192, 60 s 기준 약 100 MB입니다. iPhone에서는 길이를 60 s 이하로 두는 게 안전합니다.

## 다음 단계로 붙일 만한 것

1. **FED(Fractional Effective Dose)** 누적 계산 → 대피 가능 시간(ASET) 자동 산출
2. 두 층 **존 모델(zone model)**과 비교 검증 — 같은 입력으로 CFAST 결과와 연기층 높이를 대조
3. 3D 복셀 솔버(Metal, 64³~128³) — 단면 모드 커널은 거의 그대로 확장 가능
4. 오프라인 프레임을 HEVC로 인코딩해 메모리 대신 디스크에 저장
