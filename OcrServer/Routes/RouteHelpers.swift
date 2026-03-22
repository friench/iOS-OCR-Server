//
//  RouteHelpers.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor

/// Convert a Vapor `ByteBuffer` to Foundation `Data`.
func byteBufferToData(_ buffer: ByteBuffer) -> Data {
    var tmp = buffer
    if let bytes = tmp.readBytes(length: tmp.readableBytes) {
        return Data(bytes)
    }
    return Data()
}

/// Build an HTML response with the correct content-type header.
func htmlResponse(_ html: String, status: HTTPResponseStatus = .ok) -> Response {
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/html; charset=utf-8")
    return Response(status: status, headers: headers, body: .init(string: html))
}

/// Encode a `Content`-conforming payload as a JSON response.
func jsonResponse<T: Content>(_ status: HTTPResponseStatus, _ payload: T) throws -> Response {
    let res = Response(status: status)
    try res.content.encode(payload, as: .json)
    return res
}
