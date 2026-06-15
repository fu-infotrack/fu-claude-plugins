---
name: inspecting-orders-api
description: Use when inspecting Orders API orders — fetching an order, its request/response payloads, hierarchy, batch links, or service identifiers; or when an Orders API call needs a bearer token or returns 401 (expired token). Host, token path, login URL and username resolve from fu-tools config.
---

# Inspecting the Orders API

Host, token path, login URL and username come from fu-tools config — never hardcode
them. Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh inspecting-orders-api <key>`:

```bash
RES="${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh"
BASE=$("$RES" inspecting-orders-api baseUrl)        # e.g. https://<host>/ordersapi
LOGIN=$("$RES" inspecting-orders-api loginUrl)      # the headed-login site
TOKEN_PATH=$(eval echo "$("$RES" inspecting-orders-api tokenPath)")   # expands ~
USER=$("$RES" inspecting-orders-api username)
TOKEN=$(cat "$TOKEN_PATH")
```

All calls: `Authorization: Bearer $TOKEN`. Swagger at `$BASE/swagger/v2/swagger.json`.

## Token

Saved at the configured `tokenPath` (chmod 600; ~7-day life). The same token works for
the Orders API, every delivery-system API on the same host, and every `/services/*`
backend-for-frontend on the login host.

```bash
# validity (expect 200):
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$BASE/v2/Orders/<orderId>"
```

**Refresh on 401** (headed login, then save cookie):
```bash
playwright-cli open --browser=chromium --headed "$LOGIN"
playwright-cli snapshot   # find Username/Password textbox refs + "Log In" button
playwright-cli fill <userRef> "$USER" && playwright-cli fill <passRef> "<password>"
playwright-cli click <loginRef> && sleep 4
playwright-cli cookie-get access_token | grep -oP 'access_token=\K[A-Za-z0-9_\-\.]+' \
  > "$TOKEN_PATH"
```

## Endpoints (`/v2/Orders/...`)

| Path | Returns |
|---|---|
| `/{id}` | order: serviceId, status, parentOrderId, firstOrderIdInBatch, description, clientReference, fees, files |
| `/{id}/request` | submitted request object (search criteria, identifiers) |
| `/{id}/responses` | authority response payload(s) — array |
| `/{id}/children` | direct children only (bounded — prefer over hierarchy on big batches) |
| `/{id}/hierarchy` | whole tree, flat list (can be huge on extract-heavy batches) |
| `/{id}/rootOrder`, `/{id}/batch` | tree root; batch siblings |
| `/clientReference/{ref}` | look up by matter reference |

Hierarchy table one-liner:
```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v2/Orders/$ID/hierarchy" | python3 -c \
"import json,sys; [print(n['orderId'],'p',n['parentOrderId'],'svc',n['serviceId'],n['status'],repr(n.get('description'))[:50]) for n in json.load(sys.stdin)]"
```

## Statuses

`Waiting`/`InProgress` = running. `List` = **completed** with list results (not pending). `Complete` = done. `Error` = failed. Poll `/{id}` or `/hierarchy` every ~8s.

## Gotchas

- Trust `parentOrderId`; the hierarchy `level` field is unreliable.
- `firstOrderIdInBatch` is batch-wide (set on flat batch roots; `null` for a single order or the anchor pattern's children).
- An order's `description` is a display string with product-specific, sometimes conditional formatting — for reliable identifiers read `/{id}/request` (or the parent's, for children that only carry an artifact reference).
- The `OrderUpdated` event's `ServiceIdentifier` string tells you the order *type* only, never the identifier value — use it to filter/route, then read the request.
- Product-specific hierarchies, service-id tables, and verified sample orders: if you keep a local research dir, set `inspecting-orders-api.notesPath` in config and read from there.
