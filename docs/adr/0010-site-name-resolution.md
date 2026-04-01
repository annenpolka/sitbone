# 0010: ブラウザタイトルからのサイト名解決アルゴリズム

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka

## Context

ブラウザのウィンドウタイトルからサイト名を安定して抽出する必要がある。しかしタイトル構造はサイトによって異なる:
- "GitHub - repo/name - Chrome" → サイト名が先頭
- "Video Title - YouTube - Chrome" → サイト名が末尾
- "Question - Stack Overflow - Chrome" → サイト名が末尾

現在のパーサーは先頭セグメントのみ取得するため、YouTube等で壊れている。

## Decision

ハイブリッドアルゴリズムを採用:

1. **既知サイト検索（主軸）**: 分類済みサイト名をセグメント単位でタイトルから検索
2. **スコアリング（初回）**: 未知タイトルではセグメントをスコアリングして最有力候補を提案
3. **ブラウザアプリのGhost Teacher抑制**: Chrome自体を聞かない

### セグメント分割

` - `, ` | `, ` — `, ` – `, ` · `, ` • ` の全セパレータに対応。

### スコアリング基準

- ドメイン風（`.`を含む短い文字列）→ +2
- 短いブランド名（1-3単語）→ +1
- 先頭または末尾にある → +1
- `/`, `#`, 長い数字を含む → -2
- 長い文章風（4単語以上）→ -1
- ジャンク（"New Tab", "Home", "Untitled"）→ 除外

### 返り値

`SiteResolution { site: String?, confidence: Double, candidates: [String] }`

## Consequences

- WindowTitleParser.extractSiteName() を SiteResolution ベースに書き換え
- SiteObserver.findKnownSite(in:) を追加（セグメント単位マッチ）
- Ghost Teacherは confidence が低い場合に複数候補を提示可能
- ブラウザアプリ自体のGhost Teacher質問を抑制

## References

- Codex consultation: segment-aware matching, scoring heuristic
- emergent-engine: "サイト名を抽出するな、既知名を検索しろ"
