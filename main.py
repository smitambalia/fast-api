from fastapi import FastAPI
from datetime import datetime, timezone

app = FastAPI(
    title="Simple FastAPI Demo",
    description="Health check and sample GET endpoints",
    version="1.0.0",
)


@app.get("/health")
def health():
    """Simple health check endpoint."""
    return {
        "status": "ok",
        "service": "fast-api",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/response")
def fastapi_response():
    """GET endpoint that returns a sample FastAPI-style response."""
    return {
        "message": "Hello from FastAPI Smit Ambalia",
        "framework": "FastAPI",
        "success": True,
        "data": {
            "greeting": "Welcome",
            "items": ["health", "api", "n8n"],
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/")
def root():
    """Root endpoint with available routes."""
    return {
        "message": "Simple FastAPI Demo",
        "endpoints": {
            "health": "/health",
            "response": "/api/response",
            "docs": "/docs",
        },
    }
