//
//  OcrRoutes.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor
import Vision

/// Registers `POST /upload` and `POST /upload-pdf` for direct OCR processing.
func registerOcrRoutes(
    on app: Application,
    recognitionLevel: RecognizeTextRequest.RecognitionLevel,
    usesLanguageCorrection: Bool,
    automaticallyDetectsLanguage: Bool
) {
    // POST /upload — single image OCR (max 100 MB)
    app.on(.POST, "upload", body: .collect(maxSize: "100mb")) { req async throws -> Response in
        struct Upload: Content { var file: File }

        let upload: Upload
        do {
            upload = try req.content.decode(Upload.self)
        } catch {
            return try jsonResponse(
                .badRequest,
                UploadResponse(success: false, message: "Missing or empty 'file' part",
                               ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: [])
            )
        }

        guard upload.file.data.readableBytes > 0 else {
            return try jsonResponse(
                .badRequest,
                UploadResponse(success: false, message: "Missing or empty 'file' part",
                               ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: [])
            )
        }

        let data = byteBufferToData(upload.file.data)

        let recognizer = TextRecognizer(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: usesLanguageCorrection,
            automaticallyDetectsLanguage: automaticallyDetectsLanguage
        )

        let accept = (req.headers.first(name: .accept) ?? "").lowercased()
        let result = await recognizer.getOcrResult(data: data)

        if result == nil && accept.contains("application/json") {
            return try jsonResponse(
                .internalServerError,
                UploadResponse(success: false, message: "OCR failed",
                               ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: [])
            )
        }

        if accept.contains("application/json") {
            return try jsonResponse(
                .ok,
                UploadResponse(
                    success: true,
                    message: "File uploaded successfully",
                    ocr_result: result?.text ?? "",
                    image_width: result?.image_width ?? 0,
                    image_height: result?.image_height ?? 0,
                    ocr_boxes: result?.boxes ?? []
                )
            )
        } else {
            let html = HTMLTemplates.ocrResultPage(text: result?.text ?? "")
            return htmlResponse(html)
        }
    }

    // POST /upload-pdf — multi-page PDF OCR (max 500 MB)
    app.on(.POST, "upload-pdf", body: .collect(maxSize: "500mb")) { req async throws -> Response in
        struct Upload: Content { var file: File }

        let upload: Upload
        do {
            upload = try req.content.decode(Upload.self)
        } catch {
            return try jsonResponse(
                .badRequest,
                PDFUploadResponse(success: false, message: "Missing or empty 'file' part",
                                  page_count: 0, pages: [], full_text: "")
            )
        }

        guard upload.file.data.readableBytes > 0 else {
            return try jsonResponse(
                .badRequest,
                PDFUploadResponse(success: false, message: "Missing or empty 'file' part",
                                  page_count: 0, pages: [], full_text: "")
            )
        }

        let data = byteBufferToData(upload.file.data)

        let recognizer = TextRecognizer(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: usesLanguageCorrection,
            automaticallyDetectsLanguage: automaticallyDetectsLanguage
        )

        guard let pages = await recognizer.getOcrResultForPDF(data: data) else {
            return try jsonResponse(
                .badRequest,
                PDFUploadResponse(success: false, message: "Invalid or unsupported PDF",
                                  page_count: 0, pages: [], full_text: "")
            )
        }

        let fullText: String
        if pages.isEmpty {
            fullText = ""
        } else if pages.count == 1 {
            fullText = pages[0].text
        } else {
            var parts: [String] = []
            for (index, pageResult) in pages.enumerated() {
                if index == 0 {
                    parts.append(pageResult.text)
                } else {
                    parts.append("--- Page \(pageResult.page) ---\n\n\(pageResult.text)")
                }
            }
            fullText = parts.joined(separator: "\n\n")
        }

        return try jsonResponse(
            .ok,
            PDFUploadResponse(
                success: true,
                message: "PDF processed successfully",
                page_count: pages.count,
                pages: pages,
                full_text: fullText
            )
        )
    }
}
