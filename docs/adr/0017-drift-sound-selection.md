# 0017: DRIFT効果音の選択機能

- **Status**: accepted
- **Date**: 2026-04-09
- **Deciders**: annenpolka
- **Supersedes**: なし（ADR-0007を拡張）

## Context

ADR-0007でDRIFT遷移時の効果音を導入したが、音は`NSSound(named: "Tink")`にハードコードされている。ユーザーが好みの音を選べない。環境によって「穏やかで邪魔にならない」と感じる音は人それぞれ異なるため、選択肢を提供する。

## Decision

macOSシステムサウンドの中から効果音を選択できるようにする。

### 設計

- `SessionEngine`に`driftSoundName: String?`プロパティを追加（`nil`で無効）
- デフォルト値は`"Tink"`（現行動作を維持）
- 選択肢: macOS内蔵システムサウンド + Off
- 永続化: `persistenceRoot/settings.json`に保存（既存のkeybindings.jsonと同様のパターン）
- `onDriftEntered`コールバックの中でこのプロパティを参照して再生

### 選択可能なサウンド

Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink

### UIの変更

メニューバー設定にPickerを追加。既存のAuto-dismiss Pickerと同じパターン。

## Options Considered

### Option A: SessionEngineにサウンド名を持たせる（採用）

- **Pro**: 既存の永続化パターンに合致
- **Pro**: テストでpersistenceEnabled=falseにすればI/O不要
- **Con**: なし

### Option B: UserDefaultsで管理

- **Pro**: 実装が簡単
- **Con**: 他の設定はすべてJSONファイルで永続化しており、一貫性がない

## Consequences

- SitboneAppの`onDriftEntered`クロージャを`driftSoundName`参照に変更
- メニューバーにサウンド選択UIを追加
