# 0019: presence判定の二重閾値ヒステリシス

- **Status**: proposed
- **Date**: 2026-04-10
- **Deciders**: annenpolka

## Context

ADR-0014で導入したPresenceArbiterは、EMA平滑化したスコアを単一閾値(0.4)で判定している:

```swift
let status: PresenceStatus = smoothedScore >= threshold ? .present : .absent
```

ADR-0018実装後の本番観察 (2026-04-10) で、この単一閾値方式が境界付近で
status flip を連発することが判明した。実観測の連続イベント:

```
sensors.presence | status absent → present ema=0.422351
sensors.presence | status present → absent ema=0.399664
sensors.presence | status absent → present ema=0.430427
sensors.presence | status present → absent ema=0.300504
```

ema値が0.4の境界をまたぐたびに毎回info log が発火する。
EMAのalpha=0.3で時間方向の平滑化はしているが、平滑化結果が境界値ぴったり付近で
揺れる場合は何ticksあろうと flip が起き続ける。これはセンサーの本質的なノイズや、
顔の僅かな動き・照明変化・confidence値のわずかな変動が増幅された結果。

副作用:
- `core.session` / `sensors.presence` ログがノイズで埋まり、観察価値が下がる
- FocusStateMachineの「黙考シールド」(idle中でもpresence=presentならflow維持)が
  境界揺れによって不安定になる
- 将来的にUI上でpresence statusを表示する場合、視覚的にチカチカする

## Decision

PresenceArbiterの判定を**二重閾値 (Schmitt trigger型)** ヒステリシスに変更する。

### 設計

**閾値**:
- `presentThreshold = 0.45` — absent状態からpresentに上がるための上限
- `absentThreshold = 0.35` — present状態からabsentに落ちるための下限
- 中間域 `[0.35, 0.45]` は **現状維持**

**判定ロジック**:
```swift
let status: PresenceStatus
switch lastStatus {
case .present:
    // present継続: 0.35を下回ったときだけ離脱
    status = smoothedScore < absentThreshold ? .absent : .present
case .absent, .unknown, nil:
    // absent/初回: 0.45を超えたときだけ昇格
    status = smoothedScore >= presentThreshold ? .present : .absent
}
```

**初回判定 (lastStatus == nil)**: `presentThreshold` を使う保守的な扱い。
「不在から始まる」と見なし、明確な信号がない限りpresentと判定しない。
起動直後のカメラ未安定スコアを誤検出しない狙い。

### API変更

```swift
public init(
    sensors: [any SensorProtocol],
    presentThreshold: Double = 0.45,
    absentThreshold: Double = 0.35,
    emaAlpha: Double = 0.3,
    frameProvider: (any CameraFrameProviderProtocol)? = nil
)
```

既存の `threshold: Double = 0.4` パラメータを削除し、2パラメータに置き換える。
21箇所のcall siteはすべてデフォルト値を使用しており、明示的に `threshold` を渡している
箇所はゼロ。互換性影響なし。

不正な閾値設定 (`presentThreshold <= absentThreshold`) はinitで `precondition`
で防御する。

## Options Considered

### A: 二重閾値 (Schmitt型) — 採用

- **Pro**: 値の幅で揺れを吸収。境界付近の振動に強い
- **Pro**: シンプル、PresenceArbiter内に数行の追加で済む
- **Pro**: EMA (時間方向の平滑化) と直交した役割で、機能重複なし
- **Con**: 中間域(0.35-0.45)に長く滞在すると、初期判定の影響が長引く

### B: 永続性要求 (debounce / N連続要求)

- 同じstatusがN ticks連続で成立してから確定
- **Con**: EMAが既に時間方向のフィルタを担っているため機能重複
- **Con**: さらに反応が遅延する
- **Con**: 「3秒連続でabsent」を実装するなら、そのstateを保持する追加の仕組みが要る

### C: 二重閾値 + 永続性

- 両方を重ねる
- **Con**: この規模のアプリにはover-engineering
- **Con**: チューニングパラメータが増え、調整が複雑化

### D: EMA alphaを下げる (0.3 → 0.1)

- 平滑化を強めて境界揺れを減らす
- **Con**: ヒステリシスではなく対症療法。どこかの値で必ず境界に乗る可能性は残る
- **Con**: 反応が遅くなる (本物の入退出も遅延する)
- **Con**: 振動の振幅は減るが、境界ぴったりを跨ぐパターンには無力

### 閾値値の代替案

#### 0.45 / 0.35 (gap 0.10) — 採用
- 観察された振動 (0.300, 0.399) は両方0.35以下で `.absent` 確定
- 観察された 0.422, 0.430 は 0.45未満なので、一度absentになったら持続
- EMAが0.3で「明確に上がる」「明確に下がる」までの所要tickが3〜5
- 実用的なバランス

#### 0.50 / 0.30 (gap 0.20)
- より広い中間域、よりノイズに強い
- **Con**: 「本当にpresentになる」までtick数が多く、誤陰性リスクあり
- 0.30〜0.50の中間域に長く滞在しがちで、状態が固定されすぎる

#### 0.45 / 0.30 (非対称、sticky-present)
- absentに落ちにくくpresent寄り
- **Con**: 黙考シールドの考え方とほぼ同じで重複

### 初回判定 (lastStatus == nil) の代替案

#### presentThreshold を使う — 採用
- 「不在から始まる」保守的な扱い
- 起動直後のカメラ未安定状態が `present` と誤検出されにくい
- 既存テストの境界値 (0.286, 0.714) はどちらの閾値でも結果が同じなので破壊なし

#### absentThreshold を使う
- 「在席から始まる」オプティミスティック
- **Con**: 起動直後の誤陽性リスクあり

#### 中点 0.40 を使う
- 現状互換
- **Con**: 「3つ目の閾値」が登場し、見た目の複雑さが上がる

## Consequences

### 良い影響

- 境界付近のema揺れによる status flip ノイズが消える
- `sensors.presence` infoログが意味のある状態変化のみに絞られる
- 黙考シールドの判定が安定し、focus計測の信頼性が上がる
- ADR-0014の単一閾値設計を、観察データに基づいて進化させた記録が残る

### 悪い影響

- 「本当にpresentになる」までのtick数が増える可能性 (alpha=0.3で4〜5 tick)
- 初回判定が `presentThreshold` 基準になるため、起動直後の境界値 (0.40付近) が
  従来は `present` だったが新方式では `absent` になる
  - ただし既存テストはこの境界値を直接検証していないので破壊なし
- 閾値パラメータが1個から2個に増え、将来プロファイルごとに設定可能化する場合の
  UI/設定スキーマがやや複雑化する

### テスト戦略

ADR-0018のテスト戦略 (ロジックをテスト、ログ出力自体はテストしない) を踏襲。
新規テスト:

1. **中間域維持 (present側)**: present状態でemaが0.40に下がっても present のまま
2. **中間域維持 (absent側)**: absent状態でemaが0.40に上がっても absent のまま
3. **下限割れで離脱**: present状態でemaが0.34まで下がると absent
4. **上限超えで復帰**: absent状態でemaが0.46まで上がると present
5. **初回判定 (中間域)**: lastStatus=nil で ema=0.40 → absent (保守的)
6. **初回判定 (上限超え)**: lastStatus=nil で ema=0.50 → present
7. **初回判定 (下限割れ)**: lastStatus=nil で ema=0.20 → absent

既存テストで影響を受ける可能性のあるもの (再走確認):
- 「正規化0.286 < 0.4 → absent」: 0.286 < 0.45 でも absent ✓
- 「正規化0.714 > 0.4 → present」: 0.714 >= 0.45 で present ✓
- 「連続absentでEMAが閾値を下回る」(EMA推移 1.0 → 0.7 → 0.49 → 0.343):
  最終 0.343 < 0.35 で absent ✓
- 「alpha=1.0でEMAが即座に追従する」: 1.0→0.0 で 0.0 < 0.35 → absent ✓

## References

- [ADR-0014: PresenceArbiter初回実装](0014-presence-arbiter-initial-implementation.md)
  — 単一閾値設計の元
- [ADR-0018: Observability Logging Design](0018-observability-logging-design.md)
  — 振動を可視化したログ基盤
- 観察セッション: 2026-04-10 11:05〜11:13、log streamで実観測
- Schmitt trigger: 電気回路における二重閾値比較器の古典的設計
