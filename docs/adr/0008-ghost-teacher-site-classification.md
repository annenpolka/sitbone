# 0008: Ghost Teacher — コンテキスト内インラインサイト分類

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

ブラウザのタブ単位でFLOW/DRIFT判定したい。しかし:
- config.ymlでURL allowlistを手動設定するのは面倒で使われない
- 振る舞いベースの自動判定はYouTubeのような「画面凝視＝FLOWに見える」サイトで失敗する
- スライダーベースのFocus River UIは連続値である必要がなく、2値（FLOW/DRIFT）で十分

## Decision

**Ghost Teacher**: 未分類サイトを初めて開いた瞬間に、Notchドロップダウン内でインライン質問する。

```
┌─────────────────────────────────────┐
│ YouTube → [FLOW] [DRIFT]        ×  │
└─────────────────────────────────────┘
```

ユーザーはその場で1タップで分類。設定画面を開く必要がない。

### 判定フロー

1. SessionEngineのtickでウィンドウタイトルを取得
2. WindowTitleParser.extractSiteName()でサイト名抽出
3. SiteObserver.isNewSite()で未分類チェック
4. 未分類 → pendingGhostTeacherに設定 → UIに通知
5. ユーザーがFLOW/DRIFTをタップ → SiteObserver.classify()
6. 以降そのサイトは自動判定

### 設計原則

- **コンテキスト内**: 設定画面ではなく、まさにそのサイトを使っている瞬間に判断
- **2値**: FLOW or DRIFT。スライダーの連続値は不要（ユーザーの判断は二択）
- **1タップ**: 最小の操作コスト
- **dismissable**: ×ボタンで無視可能（undecidedのまま）
- **上書き可能**: Focus Riverで後から変更可能

## Options Considered

### Option A: Ghost Teacher (採用)

インラインで即座に分類。

- **Pro**: 判断タイミングが最適（そのサイトを使っている瞬間）
- **Pro**: 操作コスト最小（1タップ）
- **Pro**: 設定画面不要
- **Con**: 初回のみ質問。2回目以降は自動

### Option B: 自動学習のみ (The Stain)

振る舞いから自動分類。

- **Pro**: 完全自動
- **Con**: YouTubeのように振る舞いでは判定できないサイトがある
- **Con**: 学習に時間がかかる

### Option C: 設定画面での手動分類

config.ymlまたはGUI設定画面。

- **Pro**: 一括設定可能
- **Con**: 面倒で使われない
- **Con**: 設定する時とサイトを使う時の文脈が離れている

## Consequences

- SiteObserverにuserClassifications辞書を追加
- SessionEngineにpendingGhostTeacher状態を追加
- NotchDropdownにGhost Teacher UIバナーを追加
- Focus Riverは2値トグル（FLOW/DRIFT）に簡素化すべき（今後の改善）
- SiteObserver.effectiveClassification(): ユーザー分類 > 自動サジェスト の優先順位

## References

- emergent-engine出力: "Ghost Teacher" / "The Stain" / "The Membrane"
- ADR-0007: DRIFT通知の方針
