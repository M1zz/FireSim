# FireSim TODO

- [x] XcodeGen으로 FireSim.xcodeproj 생성
- [x] macOS 빌드 확인
- [x] iOS 빌드 확인

- [x] 화면 잘림 수정: iPhone(compact)용 세로 레이아웃 + 설정 시트, 차트 가로 스크롤
- [x] 메인 화면에 재생 바(시작·리셋·속도, 오프라인 재생 시 타임라인 슬라이더) 추가
- [x] 메인 화면에 평면(위에서)·단면(측면) 시점 전환 추가, 시점별 편집 상태 유지

## 남은 일 (전역 규칙 기준)
- [ ] (검토) 실시간 모드 되감기: 상태 스냅샷 저장 후 타임라인 이동
- [ ] 작은 폰트(.caption, .caption2) → .body 이상으로 교체 (ControlPanel, SensorChartView)
- [ ] 하드코딩된 한국어 문자열 → String Catalog(ko/en)로 이전
