# Sitbone

macOS native focus tracker. 一万時間の集中を計測する。

設計仕様のベースラインは `SPEC.md`。以降の設計判断は `docs/adr/` にADRとして記録する。

---

## プロジェクト構造

```
Sitbone/
├── Package.swift
├── Sources/
│   ├── Sitbone/              # App target (@main, MenuBarExtra)
│   ├── SitboneCore/          # Core logic (状態マシン, センサー融合, セッション管理)
│   ├── SitboneSensors/       # センサー実装 (Window, Idle, Camera, Gaze, Audio)
│   ├── SitboneUI/            # UI層 (NotchOverlay, DetailWindow, Components)
│   └── SitboneData/          # データ永続化 (JSON, Config)
├── Tests/
│   ├── SitboneCoreTests/
│   ├── SitboneSensorsTests/
│   └── SitboneUITests/       # Snapshot tests
├── docs/
│   └── adr/
│       ├── 0000-template.md
│       ├── 0001-sensor-fusion-for-presence-detection.md
│       ├── 0002-three-state-focus-machine.md
│       ├── 0003-json-file-persistence.md
│       ├── 0004-nonactivating-panel-for-notch-overlay.md
│       └── 0005-verification-driven-development.md
├── SPEC.md
├── CLAUDE.md
└── Makefile
```

依存の方向:

```
Sitbone (App shell)
 └→ SitboneUI
     └→ SitboneCore
         ├→ SitboneSensors
         └→ SitboneData
```

逆方向の依存は物理的に不可能（SPM target依存で強制）。

---

## Swift 6 / コンパイラ設定

Swift 6 language modeを使用。data-race safetyをコンパイル時に強制する。

```swift
// swift-tools-version: 6.0

let commonSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
    .treatWarning("DeprecatedDeclaration", as: .warning),
]
```

全ターゲットに適用する。警告ゼロポリシー。

### 型設計の原則

不正な状態を型で表現不可能にする。テストで検出するのではなく、コンパイルを通さない。

```swift
// BAD: 不正状態が表現可能
struct Counters {
    var driftRecovered: Int   // 負数を許容
}

// GOOD: 不正状態が構成不可能
struct Counter: Sendable, Codable {
    private(set) var value: Int = 0
    mutating func increment() { value += 1 }
    // 負数にする手段が構文的に存在しない
}
```

FocusStateの遷移もenumで不正な遷移を排除する:

```swift
enum FocusState: Sendable {
    case flow(since: Date)
    case drift(since: Date)
    case away(since: Date)
    // AWAY→DRIFTへの直接遷移は、tick()メソッドのswitch文に分岐が存在しないことで排除
}
```

全てのデータ型に`Sendable`を付与する。Swift 6が違反をコンパイルエラーにする。

---

## 依存注入

外部境界（時計、ファイルシステム、カメラ、NSWorkspace）をProtocolで切り出す。

```swift
// ── 境界Protocol ──

protocol ClockProtocol: Sendable {
    var now: Date { get }
}

protocol WindowMonitorProtocol: Sendable {
    func frontmostAppName() -> String?
}

protocol IdleDetectorProtocol: Sendable {
    func secondsSinceLastEvent() -> Double
}

protocol PresenceDetectorProtocol: Sendable {
    func detect() async -> PresenceReading
}

protocol SessionStoreProtocol: Sendable {
    func save(_ record: SessionRecord) async throws
    func loadDay(_ date: String) async throws -> DayRecord?
    func loadCumulative() async throws -> CumulativeRecord
    func saveCumulative(_ record: CumulativeRecord) async throws
}

// ── 依存コンテナ ──

struct Dependencies: Sendable {
    let clock: any ClockProtocol
    let windowMonitor: any WindowMonitorProtocol
    let idleDetector: any IdleDetectorProtocol
    let presenceDetector: any PresenceDetectorProtocol
    let store: any SessionStoreProtocol
}

extension Dependencies {
    static let live = Dependencies(
        clock: SystemClock(),
        windowMonitor: NSWorkspaceWindowMonitor(),
        idleDetector: CGEventSourceIdleDetector(),
        presenceDetector: CameraPresenceDetector(),
        store: JSONSessionStore()
    )

    static func test(
        clock: any ClockProtocol = FixedClock(),
        windowMonitor: any WindowMonitorProtocol = MockWindowMonitor(),
        idleDetector: any IdleDetectorProtocol = MockIdleDetector(),
        presenceDetector: any PresenceDetectorProtocol = MockPresenceDetector(),
        store: any SessionStoreProtocol = InMemorySessionStore()
    ) -> Dependencies {
        Dependencies(
            clock: clock,
            windowMonitor: windowMonitor,
            idleDetector: idleDetector,
            presenceDetector: presenceDetector,
            store: store
        )
    }
}
```

DIフレームワークは使わない。型で全てを表現する。

---

## 検証体系

信頼性の高い順に実行する。上位層で捕捉できるものを下位層に任せない。

```
型システム → コンパイラ警告 → SwiftLint → Unit Test → Sanitizer → Snapshot
(最も信頼)                                                      (最も脆い)
```

### Makefile

```makefile
SHELL        = /bin/bash
.SHELLFLAGS  = -eo pipefail -c

SCHEME       = Sitbone
DESTINATION  = platform=macOS
LOG_DIR      = .build/logs

$(LOG_DIR):
	@mkdir -p $(LOG_DIR)

install-hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit .githooks/pre-push

# Phase 1: コンパイラ検証
compile: | $(LOG_DIR)
	swift build 2>&1 | tee $(LOG_DIR)/compile.log

# Phase 2: 静的解析
lint: | $(LOG_DIR)
	swiftlint lint --strict Sources/ Tests/ 2>&1 | tee $(LOG_DIR)/lint.log

# Phase 3: ユニットテスト
test-unit: | $(LOG_DIR)
	swift test --parallel 2>&1 | tee $(LOG_DIR)/unit.log

# Phase 4: Address Sanitizer
test-asan: | $(LOG_DIR)
	xcodebuild test -scheme $(SCHEME) -destination "$(DESTINATION)" \
		-enableAddressSanitizer YES 2>&1 | tee $(LOG_DIR)/asan.log

# Phase 5: Thread Sanitizer
test-tsan: | $(LOG_DIR)
	xcodebuild test -scheme $(SCHEME) -destination "$(DESTINATION)" \
		-enableThreadSanitizer YES 2>&1 | tee $(LOG_DIR)/tsan.log

# Phase 6: Undefined Behavior Sanitizer
test-ubsan: | $(LOG_DIR)
	xcodebuild test -scheme $(SCHEME) -destination "$(DESTINATION)" \
		-enableUndefinedBehaviorSanitizer YES 2>&1 | tee $(LOG_DIR)/ubsan.log

# テストカバレッジ
coverage:
	swift test --enable-code-coverage

coverage-detail:
	swift test --enable-code-coverage
	@xcrun llvm-cov show ... > $(LOG_DIR)/coverage.txt

# .app バンドル生成・実行
app: compile
	# .build/Sitbone.app を生成（codesign含む）

run: app
	@open .build/Sitbone.app

# 全検証（早いフェーズで失敗すれば後続は不要）
verify: compile lint test-unit test-asan test-tsan test-ubsan
	@echo "=== All verification phases passed ==="
```

### SwiftLint

コンパイラが検出 **できない** ものだけをlintする。

```yaml
# .swiftlint.yml
opt_in_rules:
  - cyclomatic_complexity
  - function_body_length
  - type_body_length
  - file_length
  - closure_body_length
  - identifier_name
  - empty_count
  - first_where
  - sorted_first_last
  - modifier_order
  - sorted_imports

cyclomatic_complexity:
  warning: 10
  error: 20

function_body_length:
  warning: 40
  error: 80

type_body_length:
  warning: 250
  error: 500

file_length:
  warning: 400
  error: 800

line_length:
  warning: 120
  error: 200

excluded:
  - "**/.build"
  - "**/DerivedData"
  - "**/Fixtures"

custom_rules:
  no_print:
    name: "No print statements"
    regex: '^\s*print\s*\('
    message: "Use os.Logger instead of print()"
    severity: warning
    excluded: ".*Tests.*"
```

### テスト構造

Swift Testingを使用。XCTestは使わない（Snapshot Testのみ例外）。

```swift
import Testing
@testable import SitboneCore

struct FocusStateMachineTests {
    struct FlowState {
        @Test("idle < T1 ならFLOW維持")
        func staysInFlow() { /* ... */ }

        @Test("idle > T1 かつ presence.absent ならDRIFT遷移")
        func transitionsToDrift() { /* ... */ }

        @Test("idle > T1 かつ presence.present ならFLOW維持（黙考）")
        func contemplationKeepsFlow() { /* ... */ }
    }

    struct DriftState {
        @Test("activity復帰でFLOW + drift_recovered++")
        func recoveryIncrementsDriftRecovered() { /* ... */ }

        @Test("T2超過 かつ presence.absent でAWAY + deserted++")
        func timeoutTransitionsToAway() { /* ... */ }
    }
}

struct PresenceArbiterTests {
    @Test("カメラのみpresent → 総合present（weight 0.50 > threshold 0.4）")
    func cameraAloneSufficient() { /* ... */ }

    @Test("idleのみpresent → 総合absent（weight 0.05 < threshold 0.4）")
    func idleAloneInsufficient() { /* ... */ }

    @Test("カメラ無効時、weightが再配分される")
    func gracefulDegradation() { /* ... */ }
}
```

テストはArrange-Act-Assertの三段構成。テスト名は仕様を日本語で書く。

### Parameterized Test で閾値境界を網羅

```swift
@Test("T1境界", arguments: [14.9, 15.0, 15.1])
func t1Boundary(idle: Double) {
    // idle=14.9 → FLOW, idle=15.0 → DRIFT, idle=15.1 → DRIFT
}
```

---

## コーディング規約

### ファイル構成

1ファイル1型を基本とする。extensionでのProtocol適合は同一ファイル内に書く。

### Access Control

- モジュール内部: `internal`（デフォルト）をそのまま使う
- モジュール外部に公開: `public`を明示
- テスト: `@testable import`で`internal`にアクセス
- 「テストのためにpublicにする」は禁止

### Concurrency

- `@MainActor`はUI層のみ。Core/Sensors/Dataでは使わない
- Actor isolationはSwift 6に任せる。手動の`DispatchQueue`は使わない
- 全データ型に`Sendable`を付与

### エラーハンドリング

- `Result`型は使わない。`async throws`を使う
- ViewModel層でcatchしてUI状態に変換する
- Core/Data層はthrowsで上位に伝播

### ログ

詳細はADR-0018参照。

- `print()`禁止。`os.Logger`を使う
- カテゴリは7つに細分化:
  - `core.state` — FocusState遷移
  - `core.session` — セッション境界、プロファイル切替、Ghost Teacher、Site再分類
  - `core.lifecycle` — システムスリープ/ウェイク、アプリ起動/終了
  - `sensors.camera` — カメラセッション、デバイス初期化、フレームタイムアウト
  - `sensors.presence` — センサー融合のtick詳細とstatus変化
  - `ui.overlay` — ノッチオーバーレイ、Ghost Teacher UI、DRIFT音再生
  - `data.store` — SessionRecord/profile/設定の保存・読込・失敗
- 各モジュールの`Logging.swift`で `extension Logger` として宣言する
  （カテゴリは emit するモジュールが宣言する原則）
- レベル方針:
  - `error` — 復帰不能な失敗
  - `warning` — 機能劣化（カメラ初期化失敗など）
  - `info` — 状態遷移、セッション境界、スリープ/ウェイク（常時観察対象）
  - `debug` — presence毎tick、frame timeout（`log config --mode level:debug` で有効化）
- Privacy: 数値・enum・状態名・アプリ名は `.public`、ウィンドウタイトル・サイト名・
  ファイルパス・プロファイル名・分類値は `.private`
- 観察例:
  ```sh
  # 通常観察 (info以上) — `--level info` が必須
  /usr/bin/log stream --predicate 'subsystem == "com.sitbone"' --level info --style compact

  # 状態遷移だけ (category値はサブシステム接頭なしの "core.state")
  /usr/bin/log stream --predicate 'subsystem == "com.sitbone" AND category == "core.state"' --level info --style compact

  # debug込み（事前に有効化が必要）
  sudo /usr/bin/log config --mode 'level:debug,private_data:on' --subsystem com.sitbone
  /usr/bin/log stream --predicate 'subsystem == "com.sitbone"' --level debug --style compact
  ```
- 観察時の注意:
  - `log stream` のデフォルトレベルは `default`(notice) で、`.info` は流れない。
    `--level info` を明示しないと状態遷移ログが**全部捨てられる**ので必ず付ける
  - zshの組み込み `log`(login履歴コマンド) と衝突する。コマンドは
    `/usr/bin/log` でフルパス指定する（`alias log=/usr/bin/log` でもよい）
  - `.private` 補間値はデフォルトで `<private>` に潰される。展開したいときだけ
    `sudo log config --mode private_data:on --subsystem com.sitbone` を一度叩く
    （ユーザー機ではOFFのままが正解）

```swift
// Sources/SitboneCore/Logging.swift
import os
extension Logger {
    static let coreState     = Logger(subsystem: "com.sitbone", category: "core.state")
    static let coreSession   = Logger(subsystem: "com.sitbone", category: "core.session")
    static let coreLifecycle = Logger(subsystem: "com.sitbone", category: "core.lifecycle")
    static let sensorsPresence = Logger(subsystem: "com.sitbone", category: "sensors.presence")
}
```

---

## CI

```yaml
# .github/workflows/verify.yml
name: Verify
on:
  pull_request:
  push:
    branches: [main]

jobs:
  compile-and-lint:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift build
      - run: brew install swiftlint
      - run: make lint

  unit-tests:
    runs-on: macos-15
    needs: compile-and-lint
    steps:
      - uses: actions/checkout@v4
      - run: swift test --parallel

  sanitizers:
    runs-on: macos-15
    needs: unit-tests
    strategy:
      matrix:
        sanitizer:
          - { flag: "-enableAddressSanitizer YES", name: "ASan" }
          - { flag: "-enableThreadSanitizer YES", name: "TSan" }
          - { flag: "-enableUndefinedBehaviorSanitizer YES", name: "UBSan" }
    steps:
      - uses: actions/checkout@v4
      - name: "Run ${{ matrix.sanitizer.name }}"
        run: |
          xcodebuild test \
            -scheme Sitbone \
            -destination "platform=macOS" \
            ${{ matrix.sanitizer.flag }}
```

---

## 実装の進め方（TDD必須）

マイルストーンはSPEC.mdのロードマップに従う。v0.1から順に積み上げる。

### t_wada式 Red-Green-Refactor

**すべてのロジック実装はTDDで行う。UIレイアウトのみ例外。**

各機能で:
1. **Red**: まず失敗するテストを書く。テストが仕様の実行可能な形式
2. **Green**: テストを通す最小の実装を書く。余計なことはしない
3. **Refactor**: テストが緑のまま、コードを改善する

```
❌ 実装 → テスト（後追いテストは仕様漏れを見逃す）
✅ テスト → 実装 → リファクタ
```

### 具体的なルール

- **テストなしでCore/Sensors/Dataのロジックをコミットしない**
- 1つのテストに1つのアサーション（原則）
- テスト名は日本語で仕様を書く: `testFlowToDriftWhenIdleAboveT1AndAbsent`
- Arrange-Act-Assert の三段構成
- Mockは`SitboneSensors`モジュールのMock*クラスを使う
- 境界値テスト: T1(15s), T2(90s) の前後を必ず網羅

### テスト不要な範囲

- SwiftUI Viewのレイアウト（Snapshot Testで別途カバー）
- AppDelegate/App構造体のライフサイクル
- NSPanel/NSWindowの配置計算

### 各マイルストーンで:
1. まずProtocol（境界の型定義）を書く
2. 次にテスト（仕様の実行可能な形式）を書く
3. 最後に実装を書く
4. `swift test`が通ることを確認

テストが先、実装が後。テストはコンパイルが通る最小の実装で書き始める。

---

## ADR (Architecture Decision Records)

SPEC.mdは設計のベースライン（凍結）。**以降のあらゆる設計判断はADRで記録する。**

### ADR必須の原則

**コードに設計判断を入れる前に、必ずADRを書く。** 例外なし。「小さい変更だから」「自明だから」は理由にならない。判断の記録がないと、なぜそうなっているかが後からわからなくなる。

UIの配置方法、状態管理の設計、通知の有無、音の選択、APIの選定、SPEC.mdからの逸脱——すべてADRの対象。

### 運用ルール

- ファイル名: `NNNN-kebab-case-title.md`（0000はテンプレート予約）
- 場所: `docs/adr/`
- ステータス: `proposed` → `accepted` → (`deprecated` | `superseded by NNNN`)
- 書くタイミング: **実装の前**。ADRなしで設計変更をコードに入れない
- SPEC.mdとの矛盾が生じた場合、ADRが優先。SPEC.mdの該当箇所に「ADR-NNNNにより変更」と注記する

### 何をADRにするか

- 技術選択（ライブラリ、フレームワーク、API）
- アーキテクチャの構造変更（モジュール分割、依存方向の変更）
- データモデルの変更（スキーマ、保存形式）
- 検出/判定ロジックの閾値や重みの変更
- 却下した選択肢の記録（なぜそちらを選ばなかったか）

### 何をADRにしないか

- バグ修正
- リファクタリング（外部挙動が変わらない内部改善）
- 依存ライブラリのパッチバージョン更新
