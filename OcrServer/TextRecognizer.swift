//
//  TextRecognizer.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/1.
//

import Foundation
import Vision
import PDFKit

class TextRecognizer {
    let recognitionLevel : RecognizeTextRequest.RecognitionLevel
    let usesLanguageCorrection : Bool
    let automaticallyDetectsLanguage : Bool
    
    init(recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate,
         usesLanguageCorrection: Bool = true,
         automaticallyDetectsLanguage: Bool = true) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }
    
    func getOcrResult(data: Data) async -> OCRResult? {
        // 嘗試取影像像素大小
        guard let (W, H) = Self.imagePixelSize(from: data) else {
            return nil
        }
        
        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        
        let observations = (try? await request.perform(on: data)) ?? []
        
        var lines: [String] = []
        var items: [OCRBoxItem] = []
        
        func toPixel(_ p: NormalizedPoint) -> (Double, Double) {
            let x = Double(p.x * Double(W))
            let y = Double((1 - p.y) * Double(H))
            return (x, y)
        }
        
        for obs in observations {
            guard let best = obs.topCandidates(1).first else { continue }
            let text = best.string
            lines.append(text)
            
            // 四個角轉成像素座標（左上為原點）
            let corners = [
                CGPoint(x: obs.topLeft.x     * CGFloat(W), y: (1 - obs.topLeft.y)     * CGFloat(H)),
                CGPoint(x: obs.topRight.x    * CGFloat(W), y: (1 - obs.topRight.y)    * CGFloat(H)),
                CGPoint(x: obs.bottomRight.x * CGFloat(W), y: (1 - obs.bottomRight.y) * CGFloat(H)),
                CGPoint(x: obs.bottomLeft.x  * CGFloat(W), y: (1 - obs.bottomLeft.y)  * CGFloat(H))
            ]
            
            // 取最小外接矩形
            let minX = corners.map { $0.x }.min() ?? 0
            let maxX = corners.map { $0.x }.max() ?? 0
            let minY = corners.map { $0.y }.min() ?? 0
            let maxY = corners.map { $0.y }.max() ?? 0
            
            let rectX = Double(minX)
            let rectY = Double(minY)
            let rectW = Double(maxX - minX)
            let rectH = Double(maxY - minY)
            
            // 文字角度
            var rectItem: OCRRectItem? = nil
            if let rect = best.boundingBox(for: best.string.startIndex..<best.string.endIndex) {
                let tl = toPixel(rect.topLeft)
                let tr = toPixel(rect.topRight)
                let bl = toPixel(rect.bottomLeft)
                let br = toPixel(rect.bottomRight)

                rectItem = OCRRectItem(
                    topLeft_x: tl.0, topLeft_y: tl.1,
                    topRight_x: tr.0, topRight_y: tr.1,
                    bottomLeft_x: bl.0, bottomLeft_y: bl.1,
                    bottomRight_x: br.0, bottomRight_y: br.1
                )
            }
            
            items.append(OCRBoxItem(text: text, x: rectX, y: rectY, w: rectW, h: rectH, rect: rectItem))
        }
        
        return OCRResult(
            text: lines.joined(separator: "\n"),
            image_width: W,
            image_height: H,
            boxes: items
        )
    }
    
    func getOcrResultForPDF(data: Data) async -> [OCRPageResult]? {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            return nil
        }

        var pageResults: [OCRPageResult] = []
        let scale: CGFloat = 300.0 / 72.0

        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }

            let pageBounds = page.bounds(for: .mediaBox)
            let W = Int(pageBounds.width * scale)
            let H = Int(pageBounds.height * scale)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil, width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: W, height: H))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)

            guard let cgImage = context.makeImage() else { continue }

            var request = RecognizeTextRequest()
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = usesLanguageCorrection
            request.automaticallyDetectsLanguage = automaticallyDetectsLanguage

            let observations = (try? await request.perform(on: cgImage, orientation: .up)) ?? []

            var lines: [String] = []
            var items: [OCRBoxItem] = []

            func toPixel(_ p: NormalizedPoint) -> (Double, Double) {
                let x = Double(p.x * Double(W))
                let y = Double((1 - p.y) * Double(H))
                return (x, y)
            }

            for obs in observations {
                guard let best = obs.topCandidates(1).first else { continue }
                let text = best.string
                lines.append(text)

                let corners = [
                    CGPoint(x: obs.topLeft.x     * CGFloat(W), y: (1 - obs.topLeft.y)     * CGFloat(H)),
                    CGPoint(x: obs.topRight.x    * CGFloat(W), y: (1 - obs.topRight.y)    * CGFloat(H)),
                    CGPoint(x: obs.bottomRight.x * CGFloat(W), y: (1 - obs.bottomRight.y) * CGFloat(H)),
                    CGPoint(x: obs.bottomLeft.x  * CGFloat(W), y: (1 - obs.bottomLeft.y)  * CGFloat(H))
                ]

                let minX = corners.map { $0.x }.min() ?? 0
                let maxX = corners.map { $0.x }.max() ?? 0
                let minY = corners.map { $0.y }.min() ?? 0
                let maxY = corners.map { $0.y }.max() ?? 0

                let rectX = Double(minX)
                let rectY = Double(minY)
                let rectW = Double(maxX - minX)
                let rectH = Double(maxY - minY)

                var rectItem: OCRRectItem?
                if let rect = best.boundingBox(for: best.string.startIndex..<best.string.endIndex) {
                    let tl = toPixel(rect.topLeft)
                    let tr = toPixel(rect.topRight)
                    let bl = toPixel(rect.bottomLeft)
                    let br = toPixel(rect.bottomRight)

                    rectItem = OCRRectItem(
                        topLeft_x: tl.0, topLeft_y: tl.1,
                        topRight_x: tr.0, topRight_y: tr.1,
                        bottomLeft_x: bl.0, bottomLeft_y: bl.1,
                        bottomRight_x: br.0, bottomRight_y: br.1
                    )
                }

                items.append(OCRBoxItem(text: text, x: rectX, y: rectY, w: rectW, h: rectH, rect: rectItem))
            }

            pageResults.append(OCRPageResult(
                page: pageIndex + 1,
                text: lines.joined(separator: "\n"),
                page_width: W,
                page_height: H,
                boxes: items
            ))
        }

        return pageResults
    }

    private static func imagePixelSize(from data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        return (w, h)
    }
}
