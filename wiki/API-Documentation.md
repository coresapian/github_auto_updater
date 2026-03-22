# API Documentation for GitHub Auto Updater iOS App

This document describes the API endpoints and usage for GitHub Auto Updater iOS App.

## Base URL

```
http://localhost:8000
```

**Note:** Change the URL in production to match your deployment.


## Authentication

See repository documentation for authentication details.


## Response Format

All API endpoints return JSON responses:

```json
{{
  "status": "success",
  "data": {{...}},
  "message": "..."
}}
```

## Endpoints

### Health Check

Check if the API is running:

**Request:**
```bash
curl http://localhost:8000/health
```

**Response:**
```json
{{
  "status": "healthy",
  "version": "1.0.0"
}}
```

### Example Endpoints

**GET /api/data**

Retrieve data from the application.

**Request:**
```bash
curl http://localhost:8000/api/data
```

**Response:**
```json
{{
  "data": [...],
  "count": 10
}}
```

**POST /api/data**

Create or update data in the application.

**Request:**
```bash
curl -X POST http://localhost:8000/api/data \
  -H "Content-Type: application/json" \
  -d '{{"key": "value"}}'
```

**Response:**
```json
{{
  "status": "success",
  "data": {{...}}
}}
```

**DELETE /api/data/:id**

Delete data by ID.

**Request:**
```bash
curl -X DELETE http://localhost:8000/api/data/123
```

**Response:**
```json
{{
  "status": "success"
}}
```


## Error Codes

| Code | Description | HTTP Status |
|-------|-------------|--------------|
| 200 | Success | OK |
| 400 | Bad Request | Client Error |
| 401 | Unauthorized | Client Error |
| 404 | Not Found | Client Error |
| 500 | Internal Server Error | Server Error |

## Rate Limiting

The API may implement rate limiting to prevent abuse:

- **Default Limit:** 100 requests per minute
- **Retry After:** 60 seconds when rate limited
- **Headers:** Check `X-RateLimit-Remaining` and `X-RateLimit-Reset`

## Best Practices

- Use HTTPS in production
- Implement retry logic with exponential backoff
- Cache responses when appropriate
- Handle errors gracefully
- Validate input data before sending

## Examples

### Python Example

```python
import requests

# GET request
response = requests.get('http://localhost:8000/api/data')
print(response.json())

# POST request
data = {{'key': 'value'}}
response = requests.post('http://localhost:8000/api/data', json=data)
print(response.json())
```

### JavaScript Example

```javascript
// Using fetch
fetch('http://localhost:8000/api/data')
  .then(response => response.json())
  .then(data => console.log(data));

// POST request
fetch('http://localhost:8000/api/data', {{
  method: 'POST',
  headers: {{'Content-Type': 'application/json'}},
  body: JSON.stringify({{key: 'value'}})
}})
  .then(response => response.json())
  .then(data => console.log(data));
```

### curl Example

```bash
# GET request
curl http://localhost:8000/api/data

# POST request
curl -X POST http://localhost:8000/api/data \
  -H "Content-Type: application/json" \
  -d '{{"key": "value"}}'
```
