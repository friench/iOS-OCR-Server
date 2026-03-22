//
//  APIResponses.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor

// MARK: - Vapor Content conformance for shared models

extension OCRRectItem: Content {}
extension OCRBoxItem: Content {}
extension OCRResult: Content {}
extension OCRPageResult: Content {}

// MARK: - HTTP-specific response envelopes

/// JSON response for `POST /upload` (single image OCR).
struct UploadResponse: Content {
    let success: Bool
    let message: String
    let ocr_result: String
    let image_width: Int
    let image_height: Int
    let ocr_boxes: [OCRBoxItem]
}

/// JSON response for `POST /upload-pdf` (multi-page PDF OCR).
struct PDFUploadResponse: Content {
    let success: Bool
    let message: String
    let page_count: Int
    let pages: [OCRPageResult]
    let full_text: String
}
