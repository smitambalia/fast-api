from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from datetime import datetime, timezone
import os

app = FastAPI(
    title="Simple FastAPI Demo",
    description="Health check and sample GET endpoints",
    version="1.0.0",
)

# Allow Next.js (and other local frontends) to call the API
_cors_origins = os.getenv(
    "CORS_ORIGINS",
    "http://localhost:3000,http://127.0.0.1:3000,http://192.168.1.11:3000",
).split(",")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in _cors_origins if o.strip()],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    """Simple health check endpoint."""
    return {
        "status": "ok",
        "service": "fast-api-demo 1",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/response")
def fastapi_response():
    """GET endpoint that returns a sample FastAPI-style response."""
    return {
        "message": "Hello from FastAPI",
        "framework": "FastAPI",
        "success": True,
        "data": {
            "greeting": "Welcome",
            "items": ["health", "api", "n8n", "nextjs"],
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
