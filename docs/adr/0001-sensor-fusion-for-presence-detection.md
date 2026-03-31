# 0001: センサー融合による在席検出

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

Focus trackerは「手が止まっている」状態を検出する必要がある。しかし手が止まっている状態には「黙考」と「放置」の二種類があり、単一センサーでは区別できない。idle検出のみだとプログラマの黙考（コードを読みながら腕を組んで考える等）が離脱として誤検出される。

## Decision

複数センサーの重み付き融合（Presence Arbiter）で在席判定を行う。

## Options Considered

### Option A: センサー融合（採用）

Camera(0.50) + Gaze(0.20) + Audio(0.15) + Bluetooth(0.10) + Idle(0.05) の重み付き加重平均。normalized score > 0.4 で在席判定。

- 黙考と放置を高精度で区別できる
- カメラが使えない環境でもGraceful Degradationで動作する
- idleの重みが0.05しかないため、黙考を殺さない
- 実装が複雑。センサーごとに権限要求が必要
- カメラの1fpsキャプチャがCPU/バッテリーを消費する（要計測）

### Option B: Idle検出のみ

CGEventSource.secondsSinceLastEventType のみで判定。

- 実装が極めてシンプル。権限不要
- CPU/バッテリー消費ゼロに近い
- 黙考と放置を区別できない。これが致命的
- T1を緩めて対処すると、今度はSNS閲覧等の散漫を見逃す

### Option C: カメラのみ

顔検出だけで在席判定。

- 黙考を正しくFLOWとして判定できる
- カメラ権限が必須。カメラカバーがあると完全に動作不能
- 暗い環境で精度が落ちる
- Graceful Degradationが不可能

## Consequences

- PresenceArbiterという融合層が必要になり、テストにはモックセンサーが必須
- カメラ・マイク権限のUXフロー設計が必要
- `presence.mode`設定で3段階（camera_and_sensors / sensors_only / idle_only）を提供する必要がある
- 各センサーの重みはユーザー環境に依存するため、将来的にキャリブレーション機能が望ましい

## References

- SPEC.md「センサー融合（Presence Arbiter）」セクション
