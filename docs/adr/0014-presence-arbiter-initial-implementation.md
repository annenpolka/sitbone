# 0014: PresenceArbiter初回実装

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka

## Context

FocusStateMachineには「黙考シールド」(idle中でもpresence=presentならFLOW維持)が実装済みだが、`Dependencies.live`が`MockPresenceDetector(status: .unknown)`を使用しており、シールドが一度も発火していない。結果、15秒キーボード/マウスを触らないだけでdrift判定されてしまい、思考中の集中が正しく計測できていない。

SPEC.mdで定義されている5センサー(Camera, Gaze, Audio, Bluetooth, Idle)のうち、Camera+Gazeを先行実装し、黙考シールドを実際に機能させる。

## Decision

Camera(顔検出)+Gaze(顔の正面性+瞳孔位置)の2センサーとPresenceArbiter(融合+EMA平滑化)を実装する。Audio/Bluetooth/Idleセンサーは後続マイルストーンに延期する。

### SPEC.mdからの逸脱

1. **Gazeセンサーの簡略化**: SPEC.mdの「視線(eye direction)」を「顔の正面性(yaw/pitch) + 瞳孔位置」で代用。VNDetectFaceLandmarksのみで実装可能な範囲に限定。将来的に精度向上が必要な場合はGazeEstimatorに差し替える。

2. **EMA平滑化の追加**: SPEC.mdにはセンサー読み取りの時間的平滑化の記述がない。一瞬の視線逸脱(メモを見る、考え込むなど)で即drift判定されるのを防ぐため、指数移動平均(alpha=0.3)を融合スコアに適用する。

3. **CSVログ出力の追加**: 重みと閾値の実体験ベースでの調整を可能にするため、センサー生値・融合スコア・最終判定をCSVファイルに出力する診断機能を追加。

## Options Considered

### Option A: PresenceArbiterがPresenceDetectorProtocolを実装 (採用)

- PresenceArbiterが既存の`PresenceDetectorProtocol`をそのまま実装
- FocusStateMachine/SessionEngineの変更が不要
- `Dependencies.live`のpresenceDetectorを差し替えるだけで結合完了

### Option B: 専用のArbiterProtocolを新設

- 複数センサーの個別読み取り値を公開するAPIを持つ新Protocol
- Dependencies構造体やFocusStateMachineの変更が必要
- 利点: 個別センサー値へのアクセスが可能 → 不要(CSVログで対応)

### Option C: PresenceArbiterをActorにする

- EMA状態の保護がActor isolationで自然に実現
- Actor isolationのオーバーヘッドが毎tick発生
- detect()はSessionEngineのtickループから逐次呼び出されるため、並行アクセスは発生せず不要

## Consequences

### 良い影響

- 黙考シールドが実際に機能し、思考中のdrift誤判定が減少する
- EMA平滑化により、一瞬の視線逸脱でスコアが急変しない
- CSVログにより、重み・閾値の調整が実データに基づいて行える
- 既存のFocusStateMachineに変更なしで結合

### 悪い影響

- カメラ権限が必要になる(拒否時はpresence=unknownにフォールバック)
- Vision処理によるCPU負荷(2-3秒ごとの低解像度フレームで最小化)
- `CameraFrameProvider`/`PresenceArbiter`は`@unchecked Sendable`を使用(Swift 6 strict concurrencyの例外)

### 技術詳細

- **モジュール配置**: CameraDetector/GazeDetector → SitboneSensors、PresenceArbiter/CSVLogger → SitboneCore
- **フレーム共有**: CameraDetectorとGazeDetectorが同一CameraFrameProviderを共有。200ms TTLキャッシュで同一フレームを使用
- **EMA定数**: alpha=0.3(ハードコード)。プロファイルごとの設定可能化は必要に応じて後日追加
- **検出頻度**: SessionEngineのtickループ(2-3秒間隔)に従う
- **NSCameraUsageDescription**: SPMではInfo.plistをResourcesに直接配置できない。Xcode移行時またはビルドスクリプトでアプリバンドルに組み込む必要あり。現状はAVCameraFrameProviderが権限拒否時にnilを返すフォールバックで対応

## References

- [ADR-0001: センサー融合](0001-sensor-fusion-for-presence-detection.md)
- [ADR-0002: 三状態フォーカスマシン](0002-three-state-focus-machine.md)
- SPEC.md「センサー融合」セクション
