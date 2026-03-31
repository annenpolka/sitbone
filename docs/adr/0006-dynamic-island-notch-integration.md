# 0006: Dynamic Island風Notch統合デザイン

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka
- **Supersedes**: ADR-0004の配置方針を拡張

## Context

MacBook Pro (2021以降) の内蔵ディスプレイにはnotch（カメラ切り欠き）がある。Notchオーバーレイ（Layer 1）をnotchの真下に「notchから生えた」ように見せることで、iPhoneのDynamic Islandに近い体験を実現したい。

外部モニター使用時はnotchが存在しないため、画面上端中央にフォールバック配置する。

## Decision

NSScreen APIでnotch位置を検出し、Dynamic Island風の一体化デザインで配置する。

### Notch検出

```swift
// macOS 12+: safeAreaInsets.topが0より大きければnotchあり
let hasNotch = screen.safeAreaInsets.top > 0

// auxiliaryTopLeftArea/RightArea: notch左右の「耳」領域
// notch幅 = 画面幅 - 左耳幅 - 右耳幅
let leftEar = screen.auxiliaryTopLeftArea
let rightEar = screen.auxiliaryTopRightArea
```

### 内蔵ディスプレイ検出

CGDisplayIsBuiltin()で判定。notchがあるのは内蔵ディスプレイのみ。

### デザイン

**Compact state（常時表示）:**
- notchの直下に密着した黒いピル型
- notchと一体化して見える（角丸がnotchの角丸に連続する）
- 表示: 状態ドット + 集中時間

**Expanded state（ホバー時）:**
- 下方向にスプリングアニメーションで展開
- Honest Clock、カウンタ、タイムラインバーを表示
- 展開幅はnotch幅を超えない

**非セッション時:**
- notchのみ（オーバーレイ非表示、CPUゼロ）

## Options Considered

### Option A: Notch一体化（採用）

notchから直接UIが生えるデザイン。iPhone Dynamic Islandのmac版。

- **Pro**: 視覚的に自然、周辺視野で認識しやすい
- **Pro**: notchの「デッドスペース」を活用
- **Con**: 内蔵ディスプレイ専用のコードが必要
- **Con**: notch位置計算にAPI依存

### Option B: 画面上端フローティング

notchとは独立した位置に浮遊するバー。

- **Pro**: 実装がシンプル
- **Con**: notchと視覚的に競合、2つの黒い要素が並ぶ

### Option C: メニューバー内アイコンのみ

Layer 1を廃止し、メニューバーアイコン（Layer 0）に情報を集約。

- **Pro**: 最もシンプル
- **Con**: SPEC.mdの「周辺視野で常に見えている」要件を満たせない

## Consequences

- NSScreen.auxiliaryTopLeftArea/RightArea (macOS 12+) への依存
- CGDisplayIsBuiltin()で内蔵/外部を判定するコードが必要
- 外部モニター使用時のフォールバック配置が必要
- パネルのframeをnotch位置に動的に合わせる必要がある（画面変更時の再計算）

## References

- Apple Developer: NSScreen.safeAreaInsets, auxiliaryTopLeftArea, auxiliaryTopRightArea
- iPhone Dynamic Island デザインガイドライン
- ADR-0004: NSPanelの基本方針は継続
