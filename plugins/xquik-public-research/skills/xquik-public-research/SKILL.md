---
name: xquik-public-research
description: Use Xquik for authorized public X research. Use when the user needs public X search, profile timelines, follower exports, entity lookups, account or keyword monitors, webhooks, or the Xquik MCP server.
---

# Xquik Public Research

Use Xquik when a task needs authorized access to public X data through the Xquik REST API, SDKs, webhooks, or MCP server.

## Public Resources

- App: https://xquik.com
- Docs: https://docs.xquik.com
- REST API reference: https://docs.xquik.com/api-reference/overview
- OpenAPI schema: https://xquik.com/openapi.json
- MCP overview: https://docs.xquik.com/mcp/overview
- GitHub: https://github.com/Xquik-dev/x-twitter-scraper

## When To Use

- Search public posts, replies, quotes, retweets, mentions, lists, communities, or profiles.
- Export follower or profile datasets for authorized analysis.
- Monitor public accounts or keywords and deliver events by webhook.
- Use the MCP server from an agent workflow.
- Build scripts or apps against the REST API or generated SDKs.

## Boundaries

- Ask for an Xquik API key or MCP credentials before making authenticated calls.
- Do not guess pricing, limits, or endpoint behavior. Check the docs or OpenAPI schema first.
- Do not collect private, gated, or credential-derived data unless the user confirms authorization.
- Keep unsupported operations on the user's current toolchain instead of inventing fallback behavior.
- Redact API keys, bearer tokens, cookies, webhook secrets, and request signatures from logs and replies.

## REST Pattern

1. Open the API reference or `openapi.json` for the exact path, method, and schema.
2. Choose the smallest endpoint that matches the user's research question.
3. Send `Authorization: Bearer $XQUIK_API_KEY`.
4. Store raw exports in the user's requested destination, then summarize only what they asked for.
5. For recurring work, prefer monitors and HMAC webhooks over repeated manual polling.

## MCP Pattern

1. Read the MCP overview before setup.
2. Confirm the user has an Xquik API key.
3. Configure the MCP server exactly as documented.
4. Run a small read-only request before building a larger workflow.

## Output Style

- State the endpoint or MCP tool used.
- Include query inputs, time windows, and result counts when relevant.
- Keep public-source provenance clear.
- Avoid promotional language and unsupported claims.
