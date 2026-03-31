# 0011: セッションプロファイル

- **Status**: accepted
- **Date**: 2026-04-01
- **Deciders**: annenpolka

## Context

同じアプリでもコンテキストによってFLOW/DRIFTが変わる（Discordはcoding中はDRIFTだがcommunity活動中はFLOW）。プロファイルごとに独立したアプリ分類を持つことで、文脈依存の集中管理を実現する。

## Decision

- プロファイルごとに独立したSiteObserver（アプリ分類が核）
- いつでも切替可能（Notchドロップダウン内のProfile Pills）
- 切替時はセッション分割（累積に加算してカウンタリセット）
- Ghost Teacherはプロファイルごとにゼロから
- defaultプロファイルが初回起動時に自動生成
- 永続化は `~/.sitbone/profiles/<name>/classifications.json`
- 翼のグローカラーはプロファイルのcolorHueから生成（FLOW=明るい、DRIFT=暗い）

## Consequences

- SessionProfile型（name, colorHue, thresholds）
- SessionEngineにprofiles, activeProfile, siteObserversキャッシュ
- switchProfile()でSiteObserver差し替え + セッション分割
- Profile Pills UIをドロップダウン最上段に配置
- 旧classifications.jsonのマイグレーション対応
