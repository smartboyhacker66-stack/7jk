"""Remote MCP server exposing OpenRouter as tools (streamable HTTP, bearer-token protected)."""
import hmac
import os

import httpx
import uvicorn
from fastmcp import FastMCP
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import PlainTextResponse

API_BASE = "https://openrouter.ai/api/v1"

mcp = FastMCP("OpenRouter")


def _headers() -> dict:
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise RuntimeError("OPENROUTER_API_KEY is not set on the server.")
    return {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "X-Title": "OpenRouter MCP",
    }


async def _request(method: str, path: str, **kwargs):
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.request(method, f"{API_BASE}{path}", headers=_headers(), **kwargs)
    if resp.status_code >= 400:
        raise RuntimeError(f"OpenRouter error {resp.status_code}: {resp.text[:500]}")
    return resp.json()


@mcp.tool
async def list_models(search: str = "", limit: int = 50) -> list[dict]:
    """List OpenRouter models. Optional case-insensitive search on id or name."""
    data = (await _request("GET", "/models")).get("data", [])
    term = search.lower().strip()
    if term:
        data = [m for m in data if term in m.get("id", "").lower() or term in m.get("name", "").lower()]
    return [
        {
            "id": m.get("id"),
            "name": m.get("name"),
            "context_length": m.get("context_length"),
            "pricing": m.get("pricing"),
        }
        for m in data[: max(1, min(limit, 200))]
    ]


@mcp.tool
async def chat(
    model: str,
    prompt: str,
    system: str = "",
    temperature: float | None = None,
    max_tokens: int | None = None,
) -> str:
    """Send a single prompt to a model (for example 'openai/gpt-4o-mini') and return the reply text."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    result = await chat_messages(model, messages, temperature, max_tokens)
    return result["choices"][0]["message"]["content"] or ""


@mcp.tool
async def chat_messages(
    model: str,
    messages: list[dict],
    temperature: float | None = None,
    max_tokens: int | None = None,
) -> dict:
    """Full chat completion with a list of {role, content} messages. Returns the raw OpenRouter response."""
    body: dict = {"model": model, "messages": messages}
    if temperature is not None:
        body["temperature"] = temperature
    if max_tokens is not None:
        body["max_tokens"] = max_tokens
    return await _request("POST", "/chat/completions", json=body)


@mcp.tool
async def get_credits() -> dict:
    """Show total credits purchased and used on the OpenRouter account."""
    return (await _request("GET", "/credits")).get("data", {})


@mcp.tool
async def get_generation(generation_id: str) -> dict:
    """Look up cost and token stats for a previous generation id."""
    return (await _request("GET", "/generation", params={"id": generation_id})).get("data", {})


@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


class BearerAuth:
    """Rejects any request without the right bearer token, except /health.
    This stops strangers from spending your OpenRouter credits."""

    def __init__(self, app):
        self.app = app
        self.token = os.environ.get("MCP_AUTH_TOKEN", "")

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"] != "/health":
            supplied = ""
            for name, value in scope["headers"]:
                if name == b"authorization":
                    supplied = value.decode().removeprefix("Bearer ").strip()
            if not self.token or not hmac.compare_digest(supplied, self.token):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"Unauthorized"})
                return
        await self.app(scope, receive, send)


def build_app():
    if not os.environ.get("MCP_AUTH_TOKEN"):
        raise SystemExit("MCP_AUTH_TOKEN must be set. Refusing to start an open server.")
    return mcp.http_app(middleware=[Middleware(BearerAuth)])


if __name__ == "__main__":
    uvicorn.run(build_app(), host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
