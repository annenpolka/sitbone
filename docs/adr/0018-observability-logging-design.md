# 0018: os.Loggerによる観測ログ設計

- **Status**: proposed
- **Date**: 2026-04-10
- **Deciders**: annenpolka

## Context

現状のos.Loggerによるログ出力には複数の問題がある。

### 問題1: 利用箇所が極端に少ない

`Logger`を使っているのは2ファイルのみ:

- `Sources/SitboneCore/PresenceCSVLogger.swift:28` — category=`presence`
- `Sources/SitboneSensors/CameraFrameProvider.swift:39` — category=`sensors`

`PresenceArbiter.swift`は`import os`しているが`Logger`の利用箇所はない（死にimport）。SitboneCore/UI/Dataの大部分には`Logger`が一切無い。

### 問題2: CLAUDE.md規定のカテゴリと実装が乖離

CLAUDE.mdは「カテゴリ: `core`, `sensors`, `ui`, `data`」を規定しているが、実装には:

- `core` ➜ 存在しない
- `sensors` ➜ Cameraだけ
- `ui` ➜ 存在しない
- `data` ➜ 存在しない
- `presence` ➜ 規定にないがCSVLoggerで使用

つまり「規約が機能していない」状態。

### 問題3: presenceログが毎秒debug出力される

```
SessionEngine.startTickLoop (SitboneCore.swift:392)
  └ 1秒ごとにperformTick
      └ machine.tick (SitboneCore.swift:145)
          └ presenceDetector.detect() → PresenceArbiter.detect
              └ csvLogger?.log() → osLogger.debug("presence: ...")
```

`PresenceCSVLogger.log()`がCSV出力のおまけにos.Loggerにもdebugを出している (`PresenceCSVLogger.swift:72`)。CSVは毎秒必要だがos.Loggerには不要。`log stream`購読時にこれが他のログを埋もれさせる。

### 問題4: 文字列補間がすべて`<private>`で潰れる

`osLogger.debug("presence: \(sensorSummary) raw=\(raw) ema=\(ema) → \(entry.status.rawValue)")` のように補間しているが、os.Loggerの非数値補間は既定で`.private`扱い。`privacy: .public`を明示していないので全て`<private>`になり観察不能。

### 問題5: 観察したいイベントが軒並み記録されていない

最も重要な以下のイベントがログ・コールバックともにゼロ:

- **FocusState遷移** (`FocusStateMachine.tickFlow/tickDrift/tickAway`, SitboneCore.swift:178-256) — FLOW→DRIFT、DRIFT→FLOW、FLOW→AWAY、AWAY→FLOW
- **カウンター増加** — `deserted`, `driftRecovered`, `awayRecovered`
- **セッション境界** — `startSession` / `endSession`
- **システムスリープ/ウェイク** — `handleSystemSleep` / `handleSystemWake` (ADR-0015)
- **プロファイル切替・カメラ有効/無効・Ghost Teacher操作・Site再分類**

「最もログに載せたい状態遷移が無く、最もノイズになるpresence詳細値が毎秒垂れ流される」という皮肉な構造になっている。

ADR-0005のVerification-Driven Developmentは観察容易性を前提とするため、この状態は特にコストが高い。

## Decision

os.Loggerによる観測ログを以下の方針で再設計する。

### 1. 主目的: 開発観察と本番診断の両方

ADR-0005のVDDで状態遷移を`log stream`で観察する用途と、将来的な本番トラブル診断（sysdiagnose等）で原因追跡する用途の両方を満たす。矛盾しうる箇所（debug出力の有無）は`#if DEBUG`ではなく**os.Logger標準のlevel機構と`log config`**で切り替える。

### 2. Category設計: 細分化7つ

| Category | 用途 |
|---|---|
| `core.state` | FocusState遷移 |
| `core.session` | セッション境界、プロファイル切替、Ghost Teacher、Site再分類 |
| `core.lifecycle` | システムスリープ/ウェイク、アプリ起動/終了 |
| `sensors.camera` | カメラセッション開始/停止、デバイス初期化失敗、フレームタイムアウト |
| `sensors.presence` | センサー融合のtick詳細とstatus変化 |
| `ui.overlay` | ノッチオーバーレイ表示/非表示、Ghost Teacher UI操作 |
| `data.store` | SessionRecord保存/読込、永続化失敗 |

これにより `log stream --predicate 'category == "core.state"'` で状態遷移だけを抽出できる。`category BEGINSWITH "sensors"` のようにグループ抽出も可能。

### 3. Logger extensionはモジュールごとに分散

新モジュールは作らず、各SPMターゲットに`Logging.swift`を1ファイルずつ追加する:

```swift
// Sources/SitboneCore/Logging.swift
import os
extension Logger {
    static let coreState     = Logger(subsystem: "com.sitbone", category: "core.state")
    static let coreSession   = Logger(subsystem: "com.sitbone", category: "core.session")
    static let coreLifecycle = Logger(subsystem: "com.sitbone", category: "core.lifecycle")
}

// Sources/SitboneSensors/Logging.swift
import os
extension Logger {
    static let sensorsCamera   = Logger(subsystem: "com.sitbone", category: "sensors.camera")
    static let sensorsPresence = Logger(subsystem: "com.sitbone", category: "sensors.presence")
}

// Sources/SitboneUI/Logging.swift
import os
extension Logger {
    static let uiOverlay = Logger(subsystem: "com.sitbone", category: "ui.overlay")
}

// Sources/SitboneData/Logging.swift
import os
extension Logger {
    static let dataStore = Logger(subsystem: "com.sitbone", category: "data.store")
}
```

各モジュールは自分のカテゴリのみを宣言する。`subsystem`文字列がリテラルとして4ファイルに重複するが、これはbundle identifierと同じ「アプリ全体の定数」なので変更されない。

### 4. ログレベル方針: 標準 + log config切替

| Level | 用途 | 永続化 |
|---|---|---|
| `error` | 復帰不能な失敗 | 常時 |
| `warning` | 機能劣化（カメラ初期化失敗など） | 常時 |
| `info` | 状態遷移、セッション境界、スリープ/ウェイク | on-demand |
| `debug` | presence毎tick詳細、フレームタイムアウト | 明示有効化時のみ |

`#if DEBUG`によるコード分岐は導入しない。debugレベルは普段は出力されず、観察時のみ:

```sh
$ sudo log config --mode 'level:debug,private_data:on' --subsystem com.sitbone
$ log stream --predicate 'subsystem == "com.sitbone"' --level debug
```

通常時は`log stream --predicate 'subsystem == "com.sitbone"'`でinfo以上のみが流れる。

### 5. Privacy分類: プラグマティック

| 値の種類 | privacy | 例 |
|---|---|---|
| 数値、enum rawValue、状態名、タイムスタンプ | `.public` | `idle=18s`, `flow → drift`, `ema=0.42` |
| アプリ名 | `.public` | `Safari`, `Xcode` |
| ウィンドウタイトル、サイト名、ファイルパス、プロファイル名、Ghost Teacher分類値 | `.private` | `<private>` (権限ありで`Twitter \| @user`) |

os.Loggerの文字列補間は既定で`.private`なので、`.public`にしたい値は明示的に`\(value, privacy: .public)`と書く。`.private`は省略可能だが、可読性のため明示する方針。

開発時は`sudo log config --mode private_data:on`でprivate値も可視化される。本番ユーザーのMacでは`<private>`のまま。

### 6. イベントカタログ

#### info（常時観察対象）

```
core.state      | FLOW → DRIFT (reason=idle_timeout_present, idle=18s)
core.state      | DRIFT → FLOW (reason=activity_recovered, idle=2s, driftRecovered=7)
core.state      | FLOW → AWAY (reason=idle_timeout_absent, idle=95s, deserted=3)
core.state      | AWAY → FLOW (reason=activity_recovered, awayRecovered=2)
core.state      | FLOW → DRIFT (reason=drift_site, site=<private>)
core.state      | DRIFT → AWAY (reason=drift_timeout, duration=92s)
core.session    | session started profile=<private>
core.session    | session ended focused=45m total=58m ratio=0.78
core.session    | profile switched <private> → <private>
core.session    | ghost teacher classified site=<private> as=focus
core.session    | site reclassified <private>: drift → focus
core.lifecycle  | system sleep
core.lifecycle  | system wake
sensors.camera  | session started
sensors.camera  | session stopped (reason=user_disabled)
sensors.presence| status present → absent (ema=0.35)
ui.overlay      | drift sound played name=Tink
data.store      | saved session <private>
```

#### warning

```
sensors.camera  | device init failed
data.store      | save failed: <error>
```

#### debug（log config --mode level:debug 時のみ）

```
sensors.presence| tick raw=0.42 ema=0.38 camera=true(0.85) idle=12.3s
sensors.camera  | frame capture timeout
ui.overlay      | overlay shown
ui.overlay      | overlay hidden
```

### 7. CSVとos.Loggerの分離

`PresenceCSVLogger`からos.Logger出力を削除し、`PresenceArbiter`に責務を移す:

- **PresenceCSVLogger**: CSVファイル書き出し**のみ**
- **PresenceArbiter**: センサー融合 + status変化検知 + os.Logger出力（debug毎tick / info状態変化時）

```swift
// PresenceArbiter.swift
private struct EMAState: Sendable {
    var value: Double?
    var lastStatus: PresenceStatus?  // 新規追加
}

public func detect() async -> PresenceReading {
    // ... 既存の判定 ...

    let previousStatus = lock.withLock { state in
        let prev = state.lastStatus
        state.lastStatus = status
        return prev
    }

    Logger.sensorsPresence.debug("""
        tick raw=\(rawScore, privacy: .public) ema=\(smoothedScore, privacy: .public) \
        status=\(status.rawValue, privacy: .public)
        """)

    if let previousStatus, previousStatus != status {
        Logger.sensorsPresence.info("""
            status \(previousStatus.rawValue, privacy: .public) → \(status.rawValue, privacy: .public) \
            ema=\(smoothedScore, privacy: .public)
            """)
    }

    csvLogger?.log(entry)
    return PresenceReading(status: status, confidence: smoothedScore)
}
```

PresenceCSVLogger側からは`osLogger`プロパティと`sensorSummary`フォーマット処理を削除する。

### 8. FocusState遷移ログ: tick戻り値にreason追加

`FocusStateMachine.tick`の戻り値を `(state: FocusState, counters: Counters, reason: TransitionReason?)` に拡張する。`reason`がnilでないとき、SessionEngine.performTick が遷移ログを出力する:

```swift
let (newState, newCounters, reason) = await machine.tick(...)
if let reason {
    Logger.coreState.info("""
        transition \(oldPhase.rawValue, privacy: .public) → \(newState.phase.rawValue, privacy: .public) \
        reason=\(reason.name, privacy: .public) ...
        """)
}
```

FocusStateMachine自体はLoggerを呼ばず純粋関数性を保つ。副作用（ログ出力）はSessionEngineに集中させる。

### 9. TransitionReason: associated value enum

理由と根拠値を型で一体として表現する。`FocusStateMachine`の各分岐を精査した結果、必要なreasonは6ケース:

```swift
public enum TransitionReason: Sendable {
    /// FLOW→DRIFT: idleがdriftDelayを超え、presenceも検知できない（活動停止）
    case idleAbsent(idleSeconds: Double)

    /// FLOW→DRIFT: idleがawayDelayを超えても在席は検知（黙考シールドの打ち切り）
    case prolongedIdleWithPresence(idleSeconds: Double)

    /// FLOW→AWAY: idleがawayDelayを超え、presenceも検知できない（離席）
    case desertion(idleSeconds: Double)

    /// FLOW→DRIFT: 現在のサイト/アプリがdrift分類されている
    case driftSite

    /// DRIFT→FLOW or AWAY→FLOW: ユーザー活動が再開した
    case activityRecovered(idleSeconds: Double)

    /// DRIFT→AWAY: drift状態が長時間続き、presenceも検知できない
    case driftTimeout(driftDuration: Double)

    var name: String {
        switch self {
        case .idleAbsent:                return "idle_absent"
        case .prolongedIdleWithPresence: return "prolonged_idle_with_presence"
        case .desertion:                 return "desertion"
        case .driftSite:                 return "drift_site"
        case .activityRecovered:         return "activity_recovered"
        case .driftTimeout:              return "drift_timeout"
        }
    }
}
```

`driftSite`は associated value を持たない。サイト名はSessionEngineが`currentSite`/`currentApp`から既に保持しており、ログ出力時に別途展開できるため、`tick`引数を増やさずに済ませる。

CLAUDE.mdの「不正な状態を型で表現不可能にする」原則に従い、reasonとcontext値の不整合を構文的に排除する。テストはpattern matchingで「どの遷移ケースでどのcontext値が含まれるか」を検証できる。

### 10. テスト戦略: ロジックのみ

LoggerProtocolによる抽象化は導入しない。代わりに:

- TransitionReasonの**戻り値**をpattern matchで検証（どのreasonがどのcontext値で返るか）
- PresenceArbiterの**lastStatus更新**を内部状態として検証
- os.Logger出力そのものは検証しない（OS依存・検証価値が低い）

LoggerProtocol抽象化はCLAUDE.mdの「DIフレームワークは使わない、型で全てを表現」方針と整合しない。

## Options Considered

### Category設計

#### A: 細分化7つ（採用）
- Pro: predicate絞り込みが効く、観察用途に強い
- Pro: `BEGINSWITH "sensors"` のようなグループ絞りも可能
- Con: カテゴリ名の管理対象が増える、CLAUDE.md更新が必要

#### B: CLAUDE.md準拠の4つ（core, sensors, ui, data）
- Pro: 規約変更不要、管理が楽
- Con: 状態遷移だけ絞るにはメッセージ本文への疑似タグ付けが必要、predicateの精度が落ちる

#### C: 中間 5つ（state, session, sensors, ui, data）
- Pro: 「状態遷移だけ絞れる」の現実問題は解決
- Con: グループ階層が無く、`sensors.*`一括フィルタができない

### Logger extension配置

#### A: モジュールごとに分散（採用）
- Pro: Package.swift変更不要、依存グラフ不変
- Pro: モジュール削除/再編時にログ定義もついてくる
- Con: `"com.sitbone"`リテラルが4ファイルに重複（許容範囲）

#### B: SitboneLogging新モジュール
- Pro: 設定の一元管理、将来のprivacy helper等の置き場
- Con: 28行程度のコードのために新モジュールはover-engineering
- Con: 全モジュールがSitboneLoggingに依存→依存グラフが広がる

### ログレベル方針

#### A: 標準方針 + log config切替（採用）
- Pro: コードに分岐が残らない、DEBUG/RELEASEで同じパス
- Pro: os.Logger標準機構をそのまま使う

#### B: `#if DEBUG`でビルド切替
- Con: 両ビルドでコードパスが分岐し、デバッグ時の不一致リスク
- Con: 本番診断時にdebugレベルを後付け有効化できない

### Privacy分類

#### A: プラグマティック（採用）— アプリ名はpublic
- Pro: 観察価値が高くかつ繰り返される一般名詞（Safari等）はpublic扱いでいい
- Con: 「特定アプリの長時間使用」がログに見える

#### B: 厳格（アプリ名もprivate）
- Pro: 行動の暴露を最小化
- Con: 観察時の利便性が下がる（毎回private_data:on必要）

#### C: 急進（ほぼ全部public）
- Con: sysdiagnoseに平文で残り、プライバシー事故リスク

### 状態遷移ログの配置

#### A: tickの戻り値にreason追加（採用）
- Pro: FocusStateMachineの純粋関数性を保つ
- Pro: テストがpattern matchで強くなる
- Con: テスト14箇所の機械的修正

#### B: FocusStateMachine内で直接Logger呼び出し
- Pro: テスト修正不要
- Con: 純粋な状態計算機にIO/グローバル状態が混入

#### C: reason無し（FLOW→DRIFTだけ）
- Pro: 最小差分
- Con: 観察価値が下がる（idle超過かdrift site検知か区別できない）

### TransitionReason表現

#### A: Associated value enum（採用）
- Pro: reasonとcontext値の不整合が型レベルで排除される
- Pro: テストがpattern matchingで仕様を表現できる
- Pro: CLAUDE.mdの型設計原則と整合
- Con: nameプロパティのボイラープレート（〜10行）
- Con: SessionEngineのログ分岐がswitch化

#### B: raw String enum + TickSnapshotをpublicで返す
- Pro: enum定義がシンプル、JSON化容易
- Con: TickSnapshotのpublic化でAPI表面積が増える
- Con: reasonとcontextが分離→型が不整合状態を許す
- Con: 戻り値が4要素タプルに肥大

#### C: contextを付与しない
- Pro: 実装差分最小
- Con: 「なぜ遷移したか」の根拠値が永久に復元不能

### CSV/Logger分離

#### A: PresenceArbiterに移管（採用）
- Pro: PresenceCSVLoggerが「CSV書き出し専任」になり責務が単一化
- Pro: status変化検知もArbiterが持つ方が自然（Arbiterは判断者）

#### B: PresenceCSVLogger内でstatus変化検知
- Pro: 変更差分が最小
- Con: 「CSVLogger」という名前と責務の乖離が進む

#### C: PresenceCSVLoggerをPresenceRecorderに改名
- Con: 責務統合してしまうため、単一責任原則から遠ざかる

### テスト戦略

#### A: ロジックをテスト、ログ出力自体はテストしない（採用）
- Pro: LoggerProtocol抽象化が不要、Dependenciesが単純なまま
- Pro: TransitionReasonの戻り値検証で遷移仕様が固定される

#### B: LoggerProtocol抽象化してログ出力を検証
- Con: CLAUDE.mdの「DIフレームワーク使わず型で表現」方針と不整合
- Con: Dependenciesに新フィールド追加、ライブとテストの2系統が増える

#### C: OSLogStoreで実ログを検証
- Con: スローでフラキー、CIで不安定化リスク

### ADR構成

#### A: 1本にまとめる（採用）
- Pro: 9つの決定が密結合（カテゴリ→レベル→privacy→イベント→実装）しているので分割すると文脈が切れる

#### B/C: 2本〜複数本に分割
- Con: 過剰分割、相互参照が増える

### 実装順序

#### A: ボトムアップ4ステップ（採用）
- Step 0: ADR commit
- Step 1: Logger extension基盤 + 既存ログ移行
- Step 2: PresenceArbiterのstatus追跡 + ログ出力
- Step 3: TransitionReason + tick戻り値拡張
- Step 4: SessionEngineの他イベントログ + CLAUDE.md更新
- 各ステップで`swift test`が通る

#### B: トップダウン（仕様から）
- Con: TransitionReasonを先に入れるとテストが一時的に不安定になりコミットが太る

#### C: 一括コミット
- Con: レビュー困難、デバッグしづらい、中間状態に戻れない

## Consequences

### 良い影響

- ADR-0005のVDDで状態遷移を`log stream`で観察できるようになる
- TransitionReasonの型表現により、遷移仕様がテストで強く固定される
- presenceの毎tickログがdebug化され、infoレベル観察がノイズに埋もれない
- カテゴリ細分化により、`category == "core.state"`のような精密な絞り込みが可能
- PresenceCSVLoggerの責務が単一化（CSV書き出しのみ）
- 本番診断時もカテゴリとprivacy方針が確立しているので追跡可能

### 悪い影響

- FocusStateMachine.tickのシグネチャ変更により、テスト14箇所の機械的修正が必要
- TransitionReason定義 + nameプロパティの追加（〜30行）
- 各モジュールに`Logging.swift`が増える（4ファイル × 数行）
- CLAUDE.mdのカテゴリ規定を更新する必要がある（4カテゴリ → 7カテゴリ）

### CLAUDE.md更新

CLAUDE.mdの「ログ」セクションを以下に置き換える:

> - `print()`禁止。`os.Logger`を使う
> - カテゴリは7つ: `core.state`, `core.session`, `core.lifecycle`, `sensors.camera`, `sensors.presence`, `ui.overlay`, `data.store`
> - 各モジュールの `Logging.swift` で `extension Logger` として宣言する
> - 詳細はADR-0018を参照

### SPEC.md影響

SPEC.mdにはログ実装の規定が無いため、更新不要。

## References

- [ADR-0005: Verification-Driven Development](0005-verification-driven-development.md)
- [ADR-0014: PresenceArbiter初回実装](0014-presence-arbiter-initial-implementation.md)
- [ADR-0015: システムスリープ/ウェイク時のカメラ管理](0015-system-sleep-camera-management.md)
- CLAUDE.md「コーディング規約 > ログ」セクション
- Apple Developer Documentation: [Generating Log Messages from Your Code](https://developer.apple.com/documentation/os/logger)
