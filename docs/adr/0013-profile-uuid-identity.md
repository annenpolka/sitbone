# 0013: プロファイルの正準識別子として UUID を使う

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka
- **Supersedes**: ADR-0011, ADR-0012 の保存先パス例のうち `<name>` ベースの部分

## Context

セッションプロファイルは `name`, `colorHue`, `thresholds` を持ち、UI から rename / switch / delete される。ここで `name` をそのまま識別子や保存キーに使うと、次の問題が起きる。

- rename のたびに永続化ディレクトリの移動が必要になる
- 同名プロファイルを禁止しない限り一意性が壊れる
- SwiftUI の `Identifiable` として安定 ID が必要になる
- メモリ上のキャッシュキー (`SiteObserver`, `SessionStore`) が表示名変更の影響を受ける

実装ではすでに `SessionProfile.id: UUID` が導入され、プロファイル切替や永続化ディレクトリのキーに使われている。一方、ADR-0011 / ADR-0012 には `<name>` ベースの保存先例が残っており、実装と文書がずれていた。

## Decision

**プロファイルの正準識別子は `UUID` とし、`name` は表示用メタデータとして扱う。**

具体的には:

- `SessionProfile.id` をプロファイルの不変 ID とする
- メモリ上のキャッシュは `UUID` をキーに持つ
- 永続化ディレクトリは `~/.sitbone/profiles/<UUID>/` とする
- `name` は UI 表示、セッション記録のラベル、ユーザー編集対象としてのみ使う
- 互換性維持のために旧 `<name>` ベース保存先を読み分けない

## Options Considered

### Option A: UUID を正準識別子にする

- rename しても保存先やキャッシュキーが変わらない
- 同名プロファイルを許容できる
- SwiftUI / 永続化 / キャッシュで同じ ID を共有できる
- ディレクトリ名が人間には読みにくい

### Option B: name を正準識別子にする

- ファイルシステム上は人間に読みやすい
- rename 時にディレクトリ移動・競合解決・参照更新が必要
- 名前重複を禁止しないと壊れる
- 表示名変更が内部 ID 変更に波及してしまう

## Consequences

- `SessionProfile` は `UUID` ベースで等価判定される
- `SessionEngine.siteObservers` / `profileStores` は `UUID` キーで保持する
- 永続化の正しい構造は以下になる

```text
~/.sitbone/
├── profiles.json
└── profiles/
    ├── <UUID>/
    │   ├── classifications.json
    │   ├── cumulative.json
    │   └── sessions/
    │       └── YYYY-MM-DD.json
    └── <UUID>/
        ├── classifications.json
        ├── cumulative.json
        └── sessions/
            └── YYYY-MM-DD.json
```

- `name` ベースの旧ディレクトリは現行仕様では正規データとして扱わない
- ADR-0011 / ADR-0012 を読むときは、保存先パス例については本 ADR を優先する

## References

- [SessionProfile.swift](../../Sources/SitboneCore/SessionProfile.swift)
- [SitboneCore.swift](../../Sources/SitboneCore/SitboneCore.swift)
- ADR-0011: セッションプロファイル
- ADR-0012: プロファイル別統計とセッション履歴
