//
//  HTMLTemplates.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Foundation

enum HTMLTemplates {

    /// Landing page shown on `GET /` with curl examples and a file-upload form.
    static func homePage(port: Int) -> String {
        """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>OCR Server</title>
            <style>
                code {
                    background: #dadada;
                    padding: 2px 6px;
                    font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
                    font-size: 0.85em;
                    font-weight: 600;
                    border-radius: 5px;
                }
                pre {
                    background: #dadada;
                    padding: 16px;
                    overflow: auto;
                    font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
                    font-size: 0.85em;
                    line-height: 1.45;
                    border-radius: 5px;
                }
                pre code {
                    background: transparent;
                    padding: 0;
                    font-size: inherit;
                    color: inherit;
                    font-weight: normal;
                }
            </style>
        </head>
        <body>
            <h1>OCR Server</h1>
            <h3>Upload an image via <code>upload</code> API:</h3>
            <pre><code>curl -H "Accept: application/json" \\
              -X POST http://&lt;YOUR IP&gt;:\(port)/upload \\
              -F "file=@01.png"</code></pre>
            <hr>
            <h3>Upload a PDF via <code>upload-pdf</code> API:</h3>
            <pre><code>curl -H "Accept: application/json" \\
              -X POST http://&lt;YOUR IP&gt;:\(port)/upload-pdf \\
              -F "file=@document.pdf"</code></pre>
            <hr>
            <h3>OCR Test:</h3>
            <form action="/upload" method="post" enctype="multipart/form-data">
                <label>
                    Choose file:
                    <input type="file" name="file" required>
                </label>
                <br><br>
                <input type="submit" value="Upload file">
            </form>
        </body>
        </html>
        """
    }

    /// Page shown after a browser (non-JSON) upload to `POST /upload`.
    static func ocrResultPage(text: String) -> String {
        let escaped = htmlEscape(text)
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>OCR Server</title>
        </head>
        <body>
            <h2>OCR Result:</h2>
            <pre>\(escaped)</pre>
        </body>
        </html>
        """
    }

    /// Minimal HTML escaping to prevent XSS in rendered text.
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
