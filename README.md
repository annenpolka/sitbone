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
- カメラ (presence検出用。なくてもidle時間のみで動作する)

## Build & Run

```bash
# ビルド
swift build

# .appバンドル生成 (カメラ権限・アクセシビリティ権限に必要)
# 初回のみ自己署名証明書「Sitbone Dev」の作成が必要 (後述)
make app

# .appバンドルで起動
make run

# /Applications にインストール (release ビルド)
make install
# ユーザーディレクトリに入れたい場合
make install INSTALL_DIR=~/Applications
# アンインストール
make uninstall

# テスト
swift test

# カバレッジ
make coverage
```

初回起動時にカメラ権限とアクセシビリティ権限のダイアログが表示される。両方許可すること。

### コード署名の設定 (初回のみ)

`make app`は「Sitbone Dev」という自己署名証明書でcodesignする。ad-hoc署名だとリビルドのたびにTCC権限（カメラ・アクセシビリティ）がリセットされるため。

```bash
# 1. 証明書を生成
cat > /tmp/sitbone-cert.cfg <<'EOF'
[ req ]
default_bits = 2048
distinguished_name = req_dn
x509_extensions = codesign
prompt = no
[ req_dn ]
CN = Sitbone Dev
[ codesign ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout /tmp/key.pem -out /tmp/cert.pem \
  -days 3650 -nodes -config /tmp/sitbone-cert.cfg
openssl pkcs12 -export -out /tmp/cert.p12 -inkey /tmp/key.pem \
  -in /tmp/cert.pem -passout pass:tmp -legacy

# 2. Keychainにインポート + 信頼
security import /tmp/cert.p12 -k ~/Library/Keychains/login.keychain-db \
  -P tmp -T /usr/bin/codesign
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/cert.pem

# 3. 確認
security find-identity -v -p codesigning  # "Sitbone Dev" が表示されればOK

# 4. 一時ファイル削除
rm -f /tmp/sitbone-cert.cfg /tmp/key.pem /tmp/cert.pem /tmp/cert.p12
```

## Development

```bash
# 全検証 (compile → lint → test → sanitizers)
make verify

# Git hooks を有効化
make install-hooks

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

ローカルでは `.githooks/pre-commit` で `make lint`、`.githooks/pre-push` で `swift test` を実行する。

GitHub Actions では `pull_request` と `main` への push ごとに `make test-unit` を実行する。

## Architecture

```
Sitbone (App shell: @main, MenuBarExtra)
 └─ SitboneUI (NotchOverlay, MenuBar, Ghost Teacher)
     └─ SitboneCore (FocusStateMachine, SessionEngine, SiteObserver)
         ├─ SitboneSensors (Window, Idle, Camera, Gaze detection)
         └─ SitboneData (JSON persistence, SessionStore)
```

依存は上から下への一方向のみ。逆方向はSPMターゲット依存で物理的に不可能。

### Key concepts

| Concept | Description |
|---------|-------------|
| **FocusState** | FLOW / DRIFT / AWAY の3状態。enum + since で不正遷移を型で排除 |
| **FocusStateMachine** | idle時間 + presence判定で状態遷移。T1=15s, T2=90s |
| **PresenceArbiter** | カメラ(顔検出) + 視線(正面性)のセンサー融合。EMA平滑化で瞬間的な視線逸脱を吸収 |
| **SessionEngine** | セッション管理。tick駆動、カウンタ蓄積、プロファイル切替 |
| **SiteObserver** | アプリ/サイトの使用時間記録 + FLOW/DRIFT分類 |
| **Ghost Teacher** | 未分類サイト検出時のインライン分類UI |
| **SessionProfile** | セッション種別 (coding, writingなど)。プロファイル別に統計を蓄積 |

### Data storage

```
~/.sitbone/
├── profiles.json                    # プロファイル一覧
├── logs/
│   └── presence_*.csv               # センサー融合ログ (診断用)
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
