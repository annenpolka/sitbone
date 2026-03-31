# 0003: JSONファイル直置きによるデータ永続化

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

セッション記録と累積時間の永続化方式を決める必要がある。macOSアプリとしてSwiftData、Core Data、SQLite、JSONファイル等の選択肢がある。

## Decision

`~/.sitbone/` ディレクトリにJSONファイルを直置きする。日次ファイル分割。

## Options Considered

### Option A: JSONファイル直置き（採用）

`~/.sitbone/sessions/2026-03-31.json` のように日付ごとにファイル分割。

- バックアップが`cp`で済む。dotfilesと同じ管理ができる
- 他のツール（jq、スクリプト）から読み書きできる
- Git管理可能。データの変更履歴が追える
- フレームワーク依存ゼロ。Codableだけで完結
- 一万時間分のデータは数MBにしかならず、パフォーマンス問題は起きない
- 同時書き込みの排他制御が必要（ただしシングルプロセスなので実質不要）
- クエリ性能がない。月次集計等は全ファイルを読む必要がある

### Option B: SwiftData / Core Data

Apple純正のORM。

- iCloud同期が組み込みで使える
- クエリが高速。集計が容易
- マイグレーションの複雑さ。スキーマ変更が面倒
- デバッグが困難。.sqliteファイルの中身が見にくい
- フレームワークのバグに振り回されるリスク（SwiftDataは歴史が浅い）

### Option C: SQLite直接

GRDB等のラッパーを使う。

- クエリ性能が高い
- マイグレーションが明示的で制御可能
- 外部依存が増える
- このアプリの規模（日あたり数KB）に対してオーバーエンジニアリング

## Consequences

- `SitboneStore`はJSONEncoder/Decoderのみに依存
- 全データ型に`Codable`適合が必須
- 月次・年次集計は全日次ファイルのスキャンが必要。v1.0時点で問題になったら`cumulative.json`のキャッシュ粒度を上げる
- 将来iCloud同期が必要になった場合、この決定を再検討する可能性がある

## References

- SPEC.md「データモデル」セクション
