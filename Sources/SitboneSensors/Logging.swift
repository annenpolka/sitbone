// Logging.swift — SitboneSensors用 os.Logger カテゴリ宣言
// ADR-0018に基づく細分化カテゴリ設計

import os

extension Logger {
    /// カメラセッション、デバイス初期化、フレームタイムアウト
    static let sensorsCamera = Logger(subsystem: "com.sitbone", category: "sensors.camera")

    /// センサー融合のtick詳細とstatus変化
    static let sensorsPresence = Logger(subsystem: "com.sitbone", category: "sensors.presence")
}
