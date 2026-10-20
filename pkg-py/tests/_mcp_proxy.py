"""Test-only authenticating proxy in front of the real Connect entry point."""

import importlib
import sys

from fastapi import Request
from fastapi.responses import JSONResponse

from ._mcp_server import PACKAGE_ROOT, PROXY_KEY

sys.path.insert(0, str(PACKAGE_ROOT / "examples/connect-mcp"))
app = importlib.import_module("app").app


@app.middleware("http")
async def check_proxy_header(request: Request, call_next):
    if request.headers.get("Authorization") != "Key " + PROXY_KEY:
        return JSONResponse({"detail": "Proxy authorization required"}, status_code=401)
    return await call_next(request)
