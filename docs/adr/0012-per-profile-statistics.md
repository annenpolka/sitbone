# 0012: プロファイル別統計とセッション履歴

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka

## Context

累積統計（`cumulative.json`）がグローバル1つだけで、プロファイル別に分かれていない。`SessionRecord`型は定義済みだが永続化されておらず、セッション履歴が残らない。また`saveCumulativeData()`にカウンタ上書きバグがある（セッションローカル値で累計を上書き）。

## Decision

### プロファイル別累計

各プロファイルが独立した`cumulative.json`を持つ。グローバルの`~/.sitbone/cumulative.json`は廃止し、`~/.sitbone/profiles/<name>/cumulative.json`に移行する。

### セッション履歴

`endSession()`/`switchProfile()`時に`SessionRecord`を生成し、日別ファイル（`sessions/YYYY-MM-DD.json`）に保存する。セッション中のphase遷移は`TimelineBlock`として記録する。

### JSONSessionStore

`SessionStoreProtocol`のファイルベース実装。プロファイルごとにインスタンスを持つ（`SiteObserver`と同パターン）。

### 累計バグ修正

`saveCumulativeData()`を「既存ロード→加算→保存」に変更し、カウンタ上書きと二重計上を防止する。`CumulativeRecord.accumulate()`メソッドを加算の単一責任点とする。

### ファイル構造

```
~/.sitbone/
├── profiles.json
└── profiles/
    ├── default/
    │   ├── classifications.json
    │   ├── cumulative.json
    │   └── sessions/
    │       └── YYYY-MM-DD.json
    └── coding/
        ├── classifications.json
        ├── cumulative.json
        └── sessions/
            └── YYYY-MM-DD.json
```

## Consequences

- `JSONSessionStore`型の新規追加（`SitboneData`モジュール）
- `CumulativeRecord`に`accumulate()`メソッド追加
- `SessionEngine`にtimeline tracking、SessionRecord生成、profileStores管理を追加
- グローバル`cumulative.json`からdefaultプロファイルへのマイグレーション
- UIに累計時間表示を追加
