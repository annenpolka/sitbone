# 0002: 三状態フォーカスマシン（FLOW / DRIFT / AWAY）

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

集中状態のモデリングが必要。二値（集中/非集中）では「散漫だけどまだ席にいる」状態を表現できず、離脱カウンタの設計が困難になる。

## Decision

FLOW（集中）→ DRIFT（散漫・在席）→ AWAY（離脱）の三状態マシンを採用する。

## Options Considered

### Option A: 三状態（採用）

FLOW / DRIFT / AWAY。DRIFTが中間バッファとして機能する。

- DRIFT→FLOWの復帰が`drift_recovered`としてカウントでき、これが離脱カウンタの核心になる
- 在席だが散漫（SNS閲覧、ぼんやり）を明示的にモデリングできる
- DRIFTの滞在時間が介入設計の猶予期間になる
- 三状態の遷移条件がpresence + idleの2軸になるため、判定マトリクスが複雑

### Option B: 二値（FOCUS / AWAY）

集中しているか、いないか。

- 単純。実装が容易
- 「散漫だけどまだ戻れる」グレーゾーンが表現できない
- 離脱カウンタが「AWAY→FOCUS復帰の回数」だけになり、意志力の介在が大きい（AWAYからの復帰は意志的な判断を伴う）

### Option C: 五状態（DEEP_FLOW / FLOW / DRIFT / AWAY / GONE）

更に細かく分類。

- 理論的にはより精密なモデリングが可能
- 遷移条件が爆発的に複雑になる
- ユーザーにとって状態が多すぎて直感的でない
- YAGNI。三状態で十分な情報が得られることを先に検証すべき

## Consequences

- カウンタが三本（drift_recovered, away_recovered, deserted）になる
- `drift_recovered`が最も価値の高い指標として設計の中心に据わる
- 状態遷移がpresence判定結果に依存するため、ADR-0001のセンサー融合が前提になる
- UIのタイムラインバーは三色（mint / amber / transparent）で表現
- 閾値T1(FLOW→DRIFT), T2(DRIFT→AWAY)がセッション種別ごとに設定可能である必要がある

## References

- SPEC.md「状態マシン」セクション
- [0001](0001-sensor-fusion-for-presence-detection.md) センサー融合
