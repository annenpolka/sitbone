# Sitbone

macOS native focus tracker. 一万時間の集中を計測する。

坐骨（sitbone）-- 椅子に座る骨。一万時間座り続ける骨。
「叱らない番犬」。吠えない。ただずっと見ている。

## What it does

- **Honest Clock** -- 集中している間だけ時間が進む。2時間座っていても集中が1時間なら1時間しか計上しない
- **離脱カウンタ** -- 「やめたかったのにやめなかった回数」を数える。drift_recovered / away_recovered / deserted
- **Ghost Teacher** -- 未分類のアプリ/サイトを使い始めると、ノッチ下にバナーが出てFLOW/DRIFTを聞いてくる
- **Notch overlay** -- MacBookのノッチに統合されたウィングUI。ホバーでドロップダウン、Focus Riverでサイト分類を管理

## Requirements

- macOS 15+ (Sequoia)
- Swift 6.0+
- MacBook with notch (notch overlay用。なくても動作はする)

## Build & Run

```bash
# ビルド
swift build

# 実行
swift run Sitbone

# テスト
swift test

# カバレッジ
make coverage
```

## Development

```bash
# 全検証 (compile → lint → test → sanitizers)
make verify

# 個別フェーズ
make compile
make lint          # swiftlint --strict
make test-unit
make test-asan     # Address Sanitizer
make test-tsan     # Thread Sanitizer
make test-ubsan    # Undefined Behavior Sanitizer

# カバレッジ詳細
make coverage-detail   # .build/logs/coverage.txt に出力
```

## Architecture

```
Sitbone (App shell: @main, MenuBarExtra)
 └─ SitboneUI (NotchOverlay, MenuBar, Ghost Teacher)
     └─ SitboneCore (FocusStateMachine, SessionEngine, SiteObserver)
         ├─ SitboneSensors (Window, Idle, Presence detection)
         └─ SitboneData (JSON persistence, SessionStore)
```

依存は上から下への一方向のみ。逆方向はSPMターゲット依存で物理的に不可能。

### Key concepts

| Concept | Description |
|---------|-------------|
| **FocusState** | FLOW / DRIFT / AWAY の3状態。enum + since で不正遷移を型で排除 |
| **FocusStateMachine** | idle時間 + presence判定で状態遷移。T1=15s, T2=90s |
| **SessionEngine** | セッション管理。tick駆動、カウンタ蓄積、プロファイル切替 |
| **SiteObserver** | アプリ/サイトの使用時間記録 + FLOW/DRIFT分類 |
| **Ghost Teacher** | 未分類サイト検出時のインライン分類UI |
| **SessionProfile** | セッション種別 (coding, writingなど)。プロファイル別に統計を蓄積 |

### Data storage

```
~/.sitbone/
├── profiles.json                    # プロファイル一覧
└── profiles/
    └── <UUID>/
        ├── classifications.json     # サイト分類 (FLOW/DRIFT)
        ├── cumulative.json          # 累計統計
        └── sessions/
            └── YYYY-MM-DD.json      # 日別セッション記録
```

## Design decisions

設計判断は `docs/adr/` にADR (Architecture Decision Records) として記録。

## License

[MIT](LICENSE)
