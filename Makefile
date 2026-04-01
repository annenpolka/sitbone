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
BIN = .build/arm64-apple-macosx/debug/SitbonePackageTests.xctest/Contents/MacOS/SitbonePackageTests
PROF = .build/arm64-apple-macosx/debug/codecov/default.profdata

coverage:
	swift test --enable-code-coverage
	@echo ""
	@echo "=== Coverage (Source only, excluding Tests/.build) ==="
	@xcrun llvm-cov report "$(BIN)" -instr-profile="$(PROF)" -ignore-filename-regex='.build|Tests'

coverage-detail:
	swift test --enable-code-coverage
	@xcrun llvm-cov show "$(BIN)" -instr-profile="$(PROF)" -ignore-filename-regex='.build|Tests' \
		-format=text -show-line-counts-or-regions > $(LOG_DIR)/coverage.txt
	@echo "Coverage detail written to $(LOG_DIR)/coverage.txt"

# .app バンドル生成
APP_NAME     = Sitbone
APP_BUNDLE   = .build/$(APP_NAME).app
BINARY       = .build/debug/$(APP_NAME)
CONTENTS     = $(APP_BUNDLE)/Contents
MACOS_DIR    = $(CONTENTS)/MacOS
RESOURCES    = $(CONTENTS)/Resources

app: compile
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RESOURCES)
	@cp $(BINARY) $(MACOS_DIR)/$(APP_NAME)
	@cp -r Sources/Sitbone/Resources/Assets.xcassets $(RESOURCES)/ 2>/dev/null || true
	@cp Sources/Sitbone/Info.plist $(CONTENTS)/Info.plist
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "=== $(APP_BUNDLE) ready ==="

run: app
	@open $(APP_BUNDLE)

# 全検証（早いフェーズで失敗すれば後続は不要）
verify: compile lint test-unit test-asan test-tsan test-ubsan
	@echo "=== All verification phases passed ==="
