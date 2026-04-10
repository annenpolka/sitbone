// Logging.swift — SitboneData用 os.Logger カテゴリ宣言
// ADR-0018に基づく細分化カテゴリ設計

import os

extension Logger {
    /// SessionRecord/profile/設定の保存・読込・失敗
    static let dataStore = Logger(subsystem: "com.sitbone", category: "data.store")
}
