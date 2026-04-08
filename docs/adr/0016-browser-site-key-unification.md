# 0016: ブラウザサイトキー統一機構

- **Status**: accepted
- **Date**: 2026-04-08
- **Deciders**: annenpolka

## Context

ブラウザのサイト識別に2つの情報源がある:

1. **URL由来** (`BrowserSiteIdentity.canonicalSiteKey`): AppleScriptでURLを取得し、登録可能ドメインを抽出。例: `"zenn.dev"`
2. **タイトル由来** (`SiteResolver.resolve`): ウィンドウタイトルをセグメント分割してサイト名を推定。例: `"Zenn"`

`preferredBrowserSiteKey()`は「タイトル由来が分類済みならタイトル由来を優先」するロジックだが、これにより以下の問題が発生:

- **同一サイトが複数キーで分類される**: `"zenn.dev"`, `"Zenn"`, `"Zenn｜エンジニアのための情報共有コミュニティ"` が別々のエントリとして`classifications.json`に蓄積
- **AppleScript URL取得失敗時のフォールバック汚染**: URLが取れないtickではタイトル由来の不安定な文字列（記事タイトル、URLパス全体等）がサイトキーになる
- **Ghost Teacherの繰り返し表示**: ドメインを分類済みでも、タイトル由来の別キーが未分類扱いで再度表示される

実際の`classifications.json`で確認された重複例:
- zenn.dev: `"zenn.dev/acn_jp_sdet/articles/..."`, `"Zenn｜エンジニアのための情報共有コミュニティ"`, `"Zenn"`
- YouTube: `"YouTube"`, `"youtube.com"`
- Twitter/X: `"Twitter"`, `"x.com"`, `"ホーム / Twitter"`, 個別ツイートタイトル
- Google検索: `"Google 検索"`, 検索URL全体（クエリパラメータ込み）

## Decision

URLドメインをサイトキーの正とし、共起観測に基づくエイリアス機構でタイトル由来キーを統合する。

## Options Considered

### Option A: URLドメイン最優先 + 共起エイリアス（採用）

**変更1: `preferredBrowserSiteKey`の優先順位変更**

`browserSiteKey`（URLドメイン）が取得できた場合は、タイトル由来の分類状態に関わらず常にURLドメインを返す。

```
現行: タイトル(分類済み) > URL(分類済み) > URL > タイトル
変更: URL > タイトル(分類済み) > タイトル
```

**変更2: 共起ベースのドメイン↔タイトルエイリアス**

同一tickでURLドメインとタイトル由来サイト名が同時に取得できた場合、その対応関係を`SiteObserver`に記録する。

```
tick: URL="https://zenn.dev/..." → domain="zenn.dev", title="Zenn"
→ エイリアス記録: zenn.dev ↔ Zenn
```

- 分類は**ドメインキーに統一**: `"Zenn"`で分類済みなら`"zenn.dev"`にも適用
- エイリアスの参照は`classification(for:)`で透過的に行う
- 1ドメインに対してN個のタイトル名が紐づくことを許容（`GitHub`と`annenpolka/sitbone`等）

**変更3: 既存データのマイグレーション**

エイリアスが構築された時点で、タイトル由来キーの分類をドメインキーに移行。

- 利点: 新規汚染を即座に止め、既存データも段階的に統合できる
- 利点: エイリアスは推測ではなく観測事実に基づくため誤マッチリスクが低い
- 利点: URL取得失敗時もエイリアス経由でドメインキーの分類を参照可能
- 欠点: エイリアス記録の永続化が必要

### Option B: URLドメイン最優先のみ（エイリアスなし）

`preferredBrowserSiteKey`の優先順位だけ変更。

- 利点: 変更が最小限
- 欠点: URL取得失敗時にタイトル由来キーがフォールバックし、既存の分類を参照できない
- 欠点: 既存の汚染データは手動クリーンアップが必要

### Option C: サイト名の正規化テーブル（ハードコード）

`"YouTube" → "youtube.com"` のような変換テーブルを持つ。

- 利点: 確実なマッピング
- 欠点: メンテナンスコストが高い。新サイトに対応できない

## Consequences

- **良い影響**: Ghost Teacherの重複表示が解消される
- **良い影響**: `classifications.json`のキーがドメインベースで安定する
- **良い影響**: URL取得失敗時もエイリアス経由で正しい分類を返せる
- **悪い影響**: `SiteObserver`にエイリアステーブルの管理責務が追加される
- **悪い影響**: エイリアスの永続化形式を決める必要がある（`classifications.json`への追加 or 別ファイル）

## References

- ADR-0008: ghost-teacher-site-classification
- ADR-0009: no-default-classification
- ADR-0010: site-name-resolution
