// Logging.swift — SitboneUI用 os.Logger カテゴリ宣言
// ADR-0018に基づく細分化カテゴリ設計

import os

extension Logger {
    /// ノッチオーバーレイ表示/非表示、Ghost Teacher UI、DRIFT音再生
    static let uiOverlay = Logger(subsystem: "com.sitbone", category: "ui.overlay")
}
