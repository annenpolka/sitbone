# 0004: nonactivatingPanel によるNotchオーバーレイ

- **Status**: accepted
- **Date**: 2026-03-31
- **Deciders**: annenpolka

## Context

Notchバー（Layer 1）はセッション中に常時表示される。ユーザーがこのバーを見たりhoverしたときに、フォーカスが現在のアプリから奪われてはならない。フォーカスが奪われると自分自身がallowlist外と判定されてDRIFTが発火する自己矛盾が起きる。

## Decision

NSPanelの`.nonactivatingPanel`スタイルマスクで実装する。

## Options Considered

### Option A: NSPanel + nonactivatingPanel（採用）

```swift
let panel = NSPanel(
    contentRect: rect,
    styleMask: [.nonactivatingPanel, .borderless],
    backing: .buffered, defer: false
)
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
```

- クリックしてもフォーカスを奪わない。エディタで作業中にチラ見してもFLOWが途切れない
- `.statusBar`レベルで他のウィンドウの上に表示
- `.canJoinAllSpaces`で全デスクトップに表示
- AppKitの低レベルAPIを直接使うため、SwiftUIとの統合にNSHostingViewが必要
- macOS固有。クロスプラットフォームには使えない（このアプリでは問題にならない）

### Option B: SwiftUI Window

SwiftUIの`.windowStyle(.plain)`を使う。

- SwiftUI純粋で書ける
- フォーカスの制御が困難。`.windowLevel`は設定できるが、nonactivating相当の挙動を保証しにくい
- Claude Island等の実績あるmacOSメニューバーアプリがNSPanelを使っている

### Option C: MenuBarExtra + popover

MenuBarExtraの組み込みpopoverを使う。

- 実装が最もシンプル
- 常時表示ができない（popoverはクリックで開閉）
- Notchバーの「周辺視野で常に見えている」設計要件を満たせない

## Consequences

- UI層にAppKitのNSPanel/NSHostingView/NSVisualEffectViewが混在する
- SwiftUIのViewをNSHostingViewでラップするブリッジコードが必要
- ウィンドウの位置計算（Notch下、中央配置）をNSScreenのframe/visibleFrameから手動で行う必要がある
- hover検出はNSTrackingAreaで実装

## References

- SPEC.md「NSPanel仕様」「Layer 1: Notchバー」セクション
- Claude Island (farouqaldori/claude-island) のアーキテクチャ
