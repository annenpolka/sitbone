// Logging.swift — SitboneSensors用 os.Logger カテゴリ宣言
// ADR-0018に基づく細分化カテゴリ設計
//
// 注: sensors.presence はPresenceArbiter(SitboneCore)が emit するため
// SitboneCore/Logging.swift で宣言する。カテゴリは emit するモジュールで宣言する原則に従う。

import os

extension Logger {
    /// カメラセッション、デバイス初期化、フレームタイムアウト
    static let sensorsCamera = Logger(subsystem: "com.sitbone", category: "sensors.camera")
}
