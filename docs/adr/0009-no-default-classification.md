# 0009: デフォルト分類の廃止 — Ghost Teacher純粋モード

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka
- **Supersedes**: ADR-0008のドメインパターン自動分類部分を撤回

## Context

WindowTitleParser.defaultClassification()でハードコードされたパターンリスト（YouTube→DRIFT, GitHub→FLOW等）を使ってアプリ/サイトを自動分類していた。しかし:

- "X"が"Xcode"にマッチする等の誤分類が発生
- パターンの網羅性が原理的に担保できない（50000個のアプリを20個のパターンでカバー不可能）
- パターンのメンテナンスコストが永続的に発生
- ユーザーが使うアプリは実際には20個程度

## Decision

**デフォルト分類を全面廃止。Ghost Teacherのみで分類する。**

初回セッションで各アプリに切り替えるたびにGhost Teacherバナーが表示される。ユーザーが1タップでFLOW/DRIFTを判定。通常20個程度のアプリを初日に分類すれば、2日目以降はGhost Teacherが出ることはほぼない。

### トレードオフ

- **20タップ（1回限り）** vs **∞のパターンメンテ + 誤分類リスク**
- 初日のUXは若干うるさいが、正確性が保証される

## Consequences

- WindowTitleParser.defaultClassification() を削除
- flowPatterns / driftPatterns のハードコードリストを削除
- SessionEngine: 全アプリ/サイトの初回遭遇時にGhost Teacher表示
- WindowTitleParser.isBrowser() と extractSiteName() は維持（サイト名抽出は有用）
- 分類データの永続化（SiteObserver.toJSON/loadJSON）の重要性が上がる

## References

- emergent-engine: 「デフォルトを消せ」「20タップ vs ∞のパターンメンテ」
- ADR-0008: Ghost Teacher設計（基本方針は維持、ドメインパターン部分のみ撤回）
