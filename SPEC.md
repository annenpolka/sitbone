# Sitbone — Design Specification

**一万時間の集中を計測するmacOSネイティブアプリ。**

坐骨（sitbone）——椅子に座る骨。一万時間座り続ける骨。
「叱らない番犬」。吠えない。ただずっと見ている。

---

## コンセプト

### 離脱カウンタ

一万時間を数えるのではなく、**「やめたかったのにやめなかった回数」を数える。**
時間は受動的に流れるが、離脱衝動を乗り越えた回数は偽造できない。
一万時間の本体は、その中に含まれる約三千回の「やめなかった」でできている。

### Honest Clock

集中している間だけ時間が進む時計。2時間座っていても集中が1時間なら1時間しか計上しない。
カウンタが一万時間に達した時、それが本物の一万時間だと信じられる。

### 意志力の排除

意志力で「続ける」のではなく、「やめる」に手続きコストを課す。
続行はデフォルト。離脱が能動的選択になる。

---

## 技術スタック

- **Swift 6.1 + SwiftUI**
- **macOS 15+** (Sequoia)
- **MenuBarExtra** (macOS 13+) でメニューバー常駐
- **NSPanel** (nonactivatingPanel) でNotchオーバーレイ
- **Vision framework** でカメラ顔検出
- **AVAudioEngine** で環境音検出
- **CGEventSource** でidle検出
- **NSWorkspace** でウィンドウフォーカス検出
- **データ保存: JSONファイル** (`~/.sitbone/`)

---

## アーキテクチャ

```
Sitbone/
├── SitboneApp.swift                # @main, MenuBarExtra
├── Core/
│   ├── FocusStateMachine.swift     # FLOW/DRIFT/AWAY 状態遷移
│   ├── PresenceArbiter.swift       # センサー融合判定
│   ├── SessionManager.swift        # セッション開始/終了/積算
│   └── Counters.swift              # drift_recovered, away_recovered, deserted
├── Sensors/
│   ├── WindowMonitor.swift         # NSWorkspace.activeApplication 監視
│   ├── IdleDetector.swift          # CGEventSource.secondsSinceLastEventType
│   ├── CameraPresence.swift        # Vision VNDetectFaceRectanglesRequest
│   ├── GazeEstimator.swift         # Vision VNDetectFaceLandmarksRequest → 視線推定
│   └── AudioPresence.swift         # AVAudioEngine → RMS → 在席推定
├── UI/
│   ├── MenuBarIcon.swift           # ▽アイコン（状態で色変化）
│   ├── NotchOverlay.swift          # NSPanel, 常時表示バー + hover展開
│   ├── DetailWindow.swift          # 一日の振り返り、週次統計、累積
│   ├── SettingsView.swift          # セッション定義、allowlist、センサー設定
│   ├── GhostReplay.swift           # 前回セッションのタイムラインオーバーレイ
│   └── Components/
│       ├── TimelineBar.swift       # FLOW/DRIFT/AWAYのカラーバー描画
│       ├── CounterDisplay.swift    # ↩ ← ✕ カウンタ表示 + micro-animation
│       └── CumulativeBar.swift     # 一万時間進捗バー（グラデーション）
├── Data/
│   ├── SessionRecord.swift         # Codable struct
│   ├── DayRecord.swift             # 一日分のセッション集約
│   ├── TimelineBlock.swift         # Ghost Replay用タイムライン要素
│   ├── SessionConfig.swift         # allowlist, 閾値, センサー設定
│   └── SitboneStore.swift          # JSON読み書き (~/.sitbone/)
└── Resources/
    └── Assets.xcassets             # ▽アイコン各サイズ
```

---

## 状態マシン

### 三状態

```
FLOW  — 集中している
DRIFT — 散漫になっている（まだ在席）
AWAY  — 離脱した（不在）
```

### 遷移条件

PresenceArbiterの判定結果とidle時間の組み合わせで遷移する。

```
              presence
              .present    .absent     .unknown
         ┌──────────┬──────────┬──────────┐
idle     │          │          │          │
< T1     │  FLOW    │  FLOW    │  FLOW    │
         ├──────────┼──────────┼──────────┤
T1-T2    │  FLOW    │  DRIFT   │  DRIFT   │
         │ (黙考)   │          │          │
         ├──────────┼──────────┼──────────┤
> T2     │  DRIFT   │  AWAY    │  AWAY    │
         └──────────┴──────────┴──────────┘
```

- `T1` = 15秒（FLOW→DRIFT閾値）
- `T2` = 90秒（DRIFT→AWAY閾値）
- FLOW復帰判定: focused_window内で5秒以上のactivity

### 黙考保護（Contemplation Shield）

idle状態でもカメラが顔を検出 + gaze方向が.screenなら「黙考」としてFLOW維持。
`contemplation_max`（デフォルト300秒）を超えたらDRIFTに遷移。

### カウンタ

| カウンタ | インクリメント条件 | 意味 |
|---|---|---|
| `drift_recovered` | DRIFT → FLOW | 散漫から戻った。**最も価値が高い** |
| `away_recovered` | AWAY → FLOW/DRIFT | 離脱から戻ってきた |
| `deserted` | FLOW/DRIFT → AWAY | 離脱が確定した |

---

## センサー融合（Presence Arbiter）

### センサー一覧

| センサー | macOS API | 権限 | 重み |
|---|---|---|---|
| Camera (顔検出) | AVCaptureSession + VNDetectFaceRectanglesRequest | NSCameraUsageDescription | 0.50 |
| Gaze (視線推定) | VNDetectFaceLandmarksRequest → 瞳孔位置 | カメラ権限に含む | 0.20 |
| Audio (環境音) | AVAudioEngine → RMS | NSMicrophoneUsageDescription | 0.15 |
| Bluetooth | CBCentralManager / 接続デバイス状態 | — | 0.10 |
| Idle (キーボード/マウス) | CGEventSource.secondsSinceLastEventType | — | 0.05 |

### 融合ロジック

各センサーが `.present` / `.absent` / `.unknown` を出力。
Arbiterが重み付き加重平均で`normalized score`を算出。
`normalized > 0.4` → `.present`。

### Graceful Degradation

カメラ無効時は重み再配分: audio 0.45, bluetooth 0.30, idle 0.25。
T1を15秒→45秒に緩和。

### カメラ仕様

- 解像度: 320x240 (低解像度)
- フレームレート: 1fps
- 映像は保存しない。CMSampleBufferはVision処理後に即破棄
- ネットワーク送信しない
- 記録するのは `face_detected: Bool` のみ

### Gaze推定

```
VNDetectFaceLandmarksRequest → leftPupil, rightPupil
顔矩形に対する瞳孔の相対位置で視線方向を推定:
  .screen — 画面を見ている
  .away   — 横/上/下を向いている
  .absent — 顔なし

gaze: .away 連続時間:
  < 30秒  → FLOW維持
  30-120秒 → DRIFT
  > 120秒 → DRIFT確定
```

---

## UI設計

### レイヤー構造

```
Layer 0: メニューバーアイコン（常時表示、最小）
Layer 1: Notchバー（常時表示、周辺視野用）
Layer 2: Hover展開パネル（意図的に見たとき）
Layer 3: Detail Window（一日の振り返り時）
```

### Layer 0: メニューバーアイコン

▽（坐骨結節のミニマル化）を使用。

```
FLOW:   ▽ mint (#2DD4A8)   静かに光る。脈動なし
DRIFT:  ▽ amber (#F4A83D)  ゆっくり回転 1rpm
AWAY:   ▽ gray (#6B7280)   動きなし
```

すべての状態遷移は0.8秒のease-in-outで補間。

### Layer 1: Notchバー

MacBookのnotch下、画面上端に張り付く幅280pxのバー。
NSPanel (nonactivatingPanel) で実装。クリックしてもフォーカスを奪わない。

```
┌──────────────────────────────────┐
│ ████████░░░░████████░░██████ 1:38│
└──────────────────────────────────┘

上段(薄い): Ghost（前回セッション）
下段(濃い): 現在セッション
高さ: 20px (バー4px + 余白)
背景: NSVisualEffectView .hudWindow
```

バー色:
- █ FLOW: #2DD4A8 (mint, 80%)
- ░ DRIFT: #F4A83D (amber, 40%)
- 空白 AWAY: transparent

非セッション時は累積時間のみ表示。

### Layer 2: Hover展開パネル

Notchバーにマウスを近づけると0.3秒spring animationで下方向に展開。

表示内容:
- セッション名 + 現在状態
- タイムラインバー（拡大版）+ Ghost
- Honest Clock (focused time / elapsed time / ratio)
- カウンタ: ↩ drift_recovered, ← away_recovered, ✕ deserted
- 累積進捗バー (10,000h)

カウンタ記号体系:
```
↩  drift_recovered  (散漫から復帰)
←  away_recovered   (離脱から復帰)
✕  deserted         (離脱確定)
```

累積バーのグラデーション:
```
0h → 2500h → 5000h → 7500h → 10000h
深い藍   青緑    緑     黄金    白金
```

### Layer 3: Detail Window

メニューバーアイコン左クリックで開く。

表示内容:
- 今日のセッション一覧（時間、focused/elapsed、ratio、カウンタ）
- 週次バー（曜日ごとのfocused時間）
- 累積表示（X / 10,000h、残り推定年数、lifetime drift_recovered）

### 色彩体系

```
背景:      NSVisualEffectView .hudWindow
FLOW:      #2DD4A8 (mint)
DRIFT:     #F4A83D (amber)
AWAY:      #6B7280 (gray-500)
テキスト:   #E5E7EB (gray-200)
アクセント:  #818CF8 (indigo-400)
```

FLOW=冷色（集中は冷静）、DRIFT=暖色（散漫はぼやける）。

### アニメーション仕様

```
状態遷移:       0.8s ease-in-out
Hover展開:      0.3s spring(response: 0.35, dampingFraction: 0.8)
タイムラインバー: 1秒ごとにリアルタイム更新
カウンタ増加:    0.2s scale(1.0→1.15→1.0) + 色flash
```

### 介入設計（意志力を使わせない）

```
DRIFT突入時:     何もしない（通知は意思決定を強いるため出さない）
DRIFT 45秒経過: 画面端に小さなカウンタ表示 "[drift 0:45 / away in 0:45]"
AWAY突入時:      カウンタの色が変わるだけ。音もポップアップもなし
```

### 操作体系

```
メニューバーアイコン左クリック:  Detail Window toggle
メニューバーアイコン右クリック:  コンテキストメニュー
  - Start Session > [coding / writing / ...]
  - End Session
  - Settings
  - Quit

Notchバー hover:   Layer 2 展開
Notchバー離脱:     0.5s delay後に収束

⌘⇧S  セッション開始/終了 toggle
⌘⇧D  現在状態をNotification Centerに一度表示
```

セッション開始は明示的（⌘⇧S or メニュー）。
セッション終了はAWAY 5分継続で自動終了も可。

### 未セッション時

```
Layer 0: ▽ gray
Layer 1: 累積時間のみ、バー全面グレー
Layer 2: hover不可
検出エンジン: 停止（CPU 0%）
```

---

## データモデル

### 保存先

`~/.sitbone/`

```
~/.sitbone/
├── config.yml          # セッション定義、allowlist、センサー設定
├── sessions/
│   ├── 2026-03-31.json
│   ├── 2026-04-01.json
│   └── ...
└── cumulative.json     # 累積時間
```

### config.yml

```yaml
sessions:
  coding:
    allowlist:
      - "Terminal"
      - "VS Code"
      - "Firefox"
    focus_rules:
      - app: "Firefox"
        url_allowlist:
          - "docs.rs"
          - "developer.mozilla.org"
          - "stackoverflow.com"
        max_continuous: 300
    T1: 15
    T2: 90

  writing:
    allowlist:
      - "iA Writer"
      - "Obsidian"
    T1: 30
    T2: 120

presence:
  mode: "camera_and_sensors"  # or "sensors_only" or "idle_only"
  contemplation_shield: true
  contemplation_max: 300
```

### データ型

```swift
struct DayRecord: Codable, Sendable {
    let date: String
    var sessions: [SessionRecord]
}

struct SessionRecord: Codable, Sendable {
    let type: String
    let startedAt: Date
    let endedAt: Date
    let realElapsed: TimeInterval
    let focusedElapsed: TimeInterval
    let focusRatio: Double
    let driftRecovered: Int
    let awayRecovered: Int
    let deserted: Int
    let timeline: [TimelineBlock]
}

struct TimelineBlock: Codable, Sendable {
    let state: String  // "flow", "drift", "away"
    let duration: TimeInterval
}

struct CumulativeRecord: Codable, Sendable {
    var totalFocusedHours: Double
    var lifetimeDriftRecovered: Int
    var lifetimeAwayRecovered: Int
    var lifetimeDeserted: Int
}
```

---

## NSPanel仕様（Notchオーバーレイ）

```swift
let panel = NSPanel(
    contentRect: rect,
    styleMask: [.nonactivatingPanel, .borderless],
    backing: .buffered,
    defer: false
)
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
panel.isOpaque = false
panel.backgroundColor = .clear
```

nonactivatingPanel: クリックしてもフォーカスを奪わない。
エディタで作業中にチラ見してもFLOW状態が途切れない。

---

## 開発ロードマップ

```
v0.1  状態マシン + メニューバーアイコン（▽ mint/amber/gray）
      - FocusStateMachine, WindowMonitor, IdleDetector
      - MenuBarExtra with ▽ icon
      - 基本的なセッション開始/終了

v0.2  Notchオーバーレイ（1行表示 + hover展開）
      - NSPanel, TimelineBar, CounterDisplay
      - Layer 1 + Layer 2

v0.3  セッション記録 + Honest Clock積算
      - JSON永続化, focused_elapsed計算, cumulative.json

v0.4  カメラPresence検出
      - AVCaptureSession + Vision, PresenceArbiter
      - 黙考保護（Contemplation Shield）

v0.5  Ghost Replay overlay

v0.6  Detail Window（日次/週次統計、累積進捗バー）

v0.7  設定UI（allowlist編集、センサー設定、テスト画面）

v0.8  Gaze推定 + Audio Presence

v1.0  安定版リリース（WidgetKit、brew cask配布）
```

---

## 設計哲学

1. **「叱らない番犬」** — 吠えない。ただずっと見ている。見られていることだけで行動が変わる。
2. **意志力を使わせない** — 通知は意思決定を強いる。情報提供のみ。判断を要求しない。
3. **周辺視野で知覚できるが注意を要求しない** — 色温度と面積比の変化だけで状態を伝える。
4. **セッション開始は儀式** — 明示的に始める。「今から集中する」の宣言。
5. **センサー融合** — 単一センサーでは黙考と放置を区別できない。複数を重ねて確信にする。
6. **Graceful Degradation** — カメラなしでも動く。精度は落ちるがゼロにはならない。
