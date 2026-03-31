# 0005: 検証駆動開発（Swift 6 + 型安全 + 階層的検証）

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

LLMとの協働開発ではコード生成量が大きくなる。生成されたコードの正しさを保証する仕組みが必要。ただしこれはLLM固有の問題ではなく、ソフトウェア検証の原理原則から導出される構成である。

## Decision

検証を信頼性の高い順に階層化し、上位層で捕捉できるものを下位層に任せない。

```
型システム → コンパイラ警告 → SwiftLint → Unit Test → Sanitizer
```

## Options Considered

### Option A: 階層的検証（採用）

Swift 6 language mode + upcoming features + warnings as errors をコンパイラ層に、不正状態を型で表現不可能にする設計を型システム層に、Swift Testingを単体テスト層に配置。

- コンパイラが全コードパスの型整合性を証明する。テストは書かれたケースしか検証しない
- Swift 6のdata-race safetyはThread Sanitizerより原理的に強力（全パス vs 実行パス）
- 不正な状態が構文的に構成できなければ、その状態のテストは不要
- Swift 6の厳格モードは外部ライブラリとの統合で摩擦が生じうる
- `treatAllWarnings(as: .error)`は開発中のイテレーション速度を落とす可能性がある

### Option B: テスト中心

カバレッジ目標（例: 80%）を設定し、テストで正しさを保証する。

- 業界標準のアプローチ
- カバレッジは「全パスの正しさ」を保証しない。100%カバレッジでもバグは存在する
- 型で排除できるバグをテストで検出するのは設計の失敗

### Option C: リンター中心

SwiftLintのルールを大量に有効化して品質を担保する。

- コンパイラが検出できるものをリンターで二重検出する意味がない
- リンターはパターンマッチ。型システムは全称証明。証明力が根本的に異なる

## Consequences

- Package.swiftに`commonSwiftSettings`を定義し全ターゲットに適用
- 全データ型に`Sendable`を付与する規約
- Protocol + 手動DIコンテナ（`Dependencies`型）で外部境界を切り出す
- SwiftLintはコンパイラの補完のみ（複雑度、命名、イディオム）
- Makefileに`verify`ターゲットを定義し、全フェーズを順序実行
- GitHub ActionsのCIパイプラインで全検証をゲートにする

## References

- CLAUDE.md「検証体系」セクション
- Swift 6 Language Mode: https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/
