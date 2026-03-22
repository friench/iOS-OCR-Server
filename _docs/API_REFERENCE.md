# iOS OCR Server — API Reference

## Base URL

```
http://<device-ip>:<port>
```

Default port: `8000`. Configurable in Settings.

---

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Landing page with curl examples and upload form |
| POST | `/upload` | Single image OCR |
| POST | `/upload-pdf` | Multi-page PDF OCR |
| POST | `/process` | Receive pushed OCR job (worker mode only) |

---

## GET /

Returns an HTML page with:
- curl command examples for `/upload` and `/upload-pdf`
- A file upload form for browser-based OCR testing

---

## POST /upload

Perform OCR on a single image.

### Request

- **Content-Type**: `multipart/form-data`
- **Max size**: 100 MB
- **Field**: `file` — the image file (PNG, JPEG, TIFF, etc.)

```bash
curl -H "Accept: application/json" \
  -X POST http://<YOUR-IP>:8000/upload \
  -F "file=@image.png"
```

### Response (JSON)

When `Accept: application/json` header is present:

```json
{
  "success": true,
  "message": "File uploaded successfully",
  "ocr_result": "Hello\nWorld",
  "image_width": 1247,
  "image_height": 648,
  "ocr_boxes": [
    {
      "text": "Hello",
      "x": 429.65,
      "y": 268.00,
      "w": 201.84,
      "h": 72.00,
      "rect": {
        "topLeft_x": 429.65,
        "topLeft_y": 268.00,
        "topRight_x": 631.49,
        "topRight_y": 268.00,
        "bottomLeft_x": 429.65,
        "bottomLeft_y": 340.00,
        "bottomRight_x": 631.49,
        "bottomRight_y": 340.00
      }
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `success` | bool | Whether OCR completed successfully |
| `message` | string | Status message |
| `ocr_result` | string | Full recognized text (newline-separated) |
| `image_width` | int | Source image width in pixels |
| `image_height` | int | Source image height in pixels |
| `ocr_boxes` | array | Bounding boxes for each recognized text element |

### Response (HTML)

Without `Accept: application/json`, returns an HTML page displaying the OCR result text.

### Bounding Box Format

Each item in `ocr_boxes`:

| Field | Type | Description |
|-------|------|-------------|
| `text` | string | Recognized text for this element |
| `x` | double | Top-left X coordinate (pixels, origin = top-left) |
| `y` | double | Top-left Y coordinate (pixels) |
| `w` | double | Bounding box width (pixels) |
| `h` | double | Bounding box height (pixels) |
| `rect` | object? | Rotated bounding rectangle (4 corners) |

The `rect` object provides exact corner coordinates preserving text orientation:

| Field | Type |
|-------|------|
| `topLeft_x`, `topLeft_y` | double |
| `topRight_x`, `topRight_y` | double |
| `bottomLeft_x`, `bottomLeft_y` | double |
| `bottomRight_x`, `bottomRight_y` | double |

### Error Responses

| Status | Condition |
|--------|-----------|
| 400 | Missing or empty `file` part |
| 500 | OCR processing failed (JSON mode only) |

---

## POST /upload-pdf

Perform OCR on a multi-page PDF document. Each page is rendered at 300 DPI before OCR.

### Request

- **Content-Type**: `multipart/form-data`
- **Max size**: 500 MB
- **Field**: `file` — the PDF file

```bash
curl -H "Accept: application/json" \
  -X POST http://<YOUR-IP>:8000/upload-pdf \
  -F "file=@document.pdf"
```

### Response

```json
{
  "success": true,
  "message": "PDF processed successfully",
  "page_count": 3,
  "full_text": "Page 1 text...\n\n--- Page 2 ---\n\nPage 2 text...",
  "pages": [
    {
      "page": 1,
      "text": "Page 1 text...",
      "page_width": 2550,
      "page_height": 3300,
      "boxes": [ ... ]
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `success` | bool | Whether processing completed |
| `message` | string | Status message |
| `page_count` | int | Number of pages processed |
| `full_text` | string | All pages concatenated with page separators |
| `pages` | array | Per-page OCR results |

Each page object:

| Field | Type | Description |
|-------|------|-------------|
| `page` | int | 1-based page number |
| `text` | string | Recognized text for this page |
| `page_width` | int | Rendered page width (pixels at 300 DPI) |
| `page_height` | int | Rendered page height (pixels at 300 DPI) |
| `boxes` | array | Bounding boxes (same format as `/upload`) |

### Error Responses

| Status | Condition |
|--------|-----------|
| 400 | Missing file or invalid/unsupported PDF |

---

## POST /process (Worker Mode)

Receives a pushed OCR job from the API server. Only registered when worker mode is enabled.

See [WORKER_DEVELOPMENT_GUIDE.md](WORKER_DEVELOPMENT_GUIDE.md) for the full worker protocol specification.

### Request

```json
{
  "jobId": "job-789",
  "documentId": "doc-456",
  "fileDownloadUrl": "https://storage.example.com/presigned/image.png",
  "callbackUrl": "https://api.example.com/api/v1/ocr-jobs/job-789/callback",
  "language": "en"
}
```

### Response

```
202 Accepted
{ "status": "accepted" }
```

The job is processed asynchronously. Results are delivered via the callback URL.

---

## Python Examples

### Simple Upload

```python
import requests

url = "http://10.0.1.11:8000/upload"
file_path = "image.png"

with open(file_path, "rb") as f:
    response = requests.post(
        url,
        files={"file": f},
        headers={"Accept": "application/json"},
    )

data = response.json()
print("Text:", data["ocr_result"])
print("Boxes:", len(data["ocr_boxes"]))
```

### PDF Upload

```python
import requests

url = "http://10.0.1.11:8000/upload-pdf"

with open("document.pdf", "rb") as f:
    response = requests.post(
        url,
        files={"file": f},
        headers={"Accept": "application/json"},
    )

data = response.json()
print(f"Pages: {data['page_count']}")
print(f"Full text:\n{data['full_text']}")
```
