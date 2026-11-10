# OpenRouter MCP Server

A remote MCP server (FastMCP, streamable HTTP) that gives MCP clients access to OpenRouter.

## Tools

- list_models: search the OpenRouter model catalog
- chat: one prompt in, one reply out
- chat_messages: full multi-message chat completion
- get_credits: account credit balance
- get_generation: cost and token stats for a past request

## Security

The server refuses to start without MCP_AUTH_TOKEN. Every request except /health must send
`Authorization: Bearer <MCP_AUTH_TOKEN>`. Your OpenRouter key lives only in Render's environment.

## Deploy

Run `bash deploy.sh` (Linux, macOS, WSL, or Git Bash on Windows). It pushes to GitHub, creates the Render
service through the Render API, asks for your OpenRouter key only at that point, waits for the deploy,
and prints the final HTTPS MCP URL.

Without a Render API key, the script prints a Render Blueprint link instead. render.yaml sets everything up.

## Run locally

    pip install -r requirements.txt
    export OPENROUTER_API_KEY=your-key
    export MCP_AUTH_TOKEN=any-long-random-string
    python server.py

The MCP endpoint is http://localhost:8000/mcp and the health check is http://localhost:8000/health.

## Note

Render's free plan sleeps after inactivity, so the first request after a pause can take about a minute.
