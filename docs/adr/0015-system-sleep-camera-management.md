# 0015: システムスリープ時のカメラ停止と時間計測保護

- **Status**: proposed
- **Date**: 2026-04-02
- **Deciders**: annenpolka

## Context

Macがスリープすると2つの問題が発生する:

1. **カメラが停止されない**: AVCaptureSessionが明示的に停止されず、スリープ中もリソースを保持する。ウェイク後にセッションが不定状態になる可能性がある。
2. **時間計測の膨張**: `advanceElapsed`が`lastTickTime`からの壁時計差分を計算するため、30分のスリープ後に最初のtickで約1800秒が`totalElapsed`/`focusedElapsed`に加算される。

## Decision

`SessionEngine`に`handleSystemSleep()`と`handleSystemWake()`を追加する。AppDelegateで`NSWorkspace.willSleepNotification`/`didWakeNotification`を購読し、これらのメソッドを呼び出す。

## Options Considered

### Option A: SessionEngineメソッド + AppDelegate直接購読（採用）

- SessionEngineに`handleSystemSleep()`/`handleSystemWake()`を追加
- AppDelegateがNSWorkspace通知を購読してメソッドを呼び出す
- 利点: テスト可能（メソッド単体でテスト可能）、既存パターンと一貫（AppDelegate→SessionEngine）
- 欠点: 通知購読自体はテストされない

### Option B: SystemSleepMonitorProtocol + DI（不採用）

- 新Protocol `SystemSleepMonitorProtocol` をSitboneSensorsに追加
- Dependenciesに注入、Mock/Spyでテスト
- 利点: 完全にDI化、通知購読もテスト可能
- 欠点: 2つの通知購読に対してProtocol + Mock + DI変更は過剰。テスト対象はSessionEngineの応答であり通知源ではない

### Option C: スリープのみ対応、ウェイク無視（不採用）

- `handleSystemSleep()`のみ実装、カメラの遅延起動に任せる
- 利点: 最小実装
- 欠点: 時間膨張バグが残る。スリープ中にtickループが停止しないためリソース消費

## Consequences

- スリープ時にカメラLEDが消灯し、ユーザーに安心感を与える
- スリープ/ウェイクを跨いだ時間計測が正確になる
- tickループ生成の共通化（`startTickLoop()`抽出）により、`startSession()`/`handleSystemWake()`の重複が解消される

## References

- ADR-0014: PresenceArbiter初期実装
- ADR-0001: センサー融合によるPresence検出
