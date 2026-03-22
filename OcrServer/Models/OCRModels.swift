//
//  OCRModels.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Foundation

/// Four-corner bounding rectangle in pixel coordinates (origin = top-left).
struct OCRRectItem: Codable, Sendable {
    let topLeft_x: Double
    let topLeft_y: Double
    let topRight_x: Double
    let topRight_y: Double
    let bottomLeft_x: Double
    let bottomLeft_y: Double
    let bottomRight_x: Double
    let bottomRight_y: Double
}

/// A single recognised text element with its axis-aligned bounding box
/// and optional rotated rectangle.
struct OCRBoxItem: Codable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let rect: OCRRectItem?
}

/// Aggregated OCR output for a single image.
struct OCRResult: Codable, Sendable {
    let text: String
    let image_width: Int
    let image_height: Int
    let boxes: [OCRBoxItem]
}

/// OCR output for a single page within a PDF document.
struct OCRPageResult: Codable, Sendable {
    let page: Int
    let text: String
    let page_width: Int
    let page_height: Int
    let boxes: [OCRBoxItem]
}
