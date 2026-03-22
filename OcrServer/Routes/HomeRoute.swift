//
//  HomeRoute.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor

/// Registers `GET /` — the landing page with curl examples and a test form.
func registerHomeRoute(on app: Application, port: Int) {
    app.get { req async throws -> Response in
        let html = HTMLTemplates.homePage(port: port)
        return htmlResponse(html)
    }
}
