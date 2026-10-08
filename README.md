# Seattle parking

Ask your phone, by voice:

- **"What are the parking rules here?"** → "You're on 14th Avenue East between East Republican Street and East Mercer Street. East side: free, 2-hour limit without a zone 4 permit. West side: free, no posted time limit. You're inside Restricted Parking Zone 4, Capitol Hill, in effect Monday-Saturday 7 AM to 6 PM."
- **"Where can I park?"** → "The closest spot is about 200 feet south, on East Olive Way between Harvard Avenue East and Broadway East, north side: paid, $1.00 an hour until 11 AM, 2-hour limit. Next is…"

It's a small Node server that looks up the City of Seattle's live SDOT parking data for a latitude/longitude (or a spoken address) and answers with a sentence ready to be read aloud, plus structured JSON. It can be used three ways:

| Client | How | Location |
| --- | --- | --- |
| **Siri** | An iOS Shortcut calls the REST API | Phone GPS, automatic |
| **ChatGPT** (voice or text) | A custom GPT Action (`/openapi.json`) or an MCP connector (`/mcp`) | You say where you are ("I'm at Broadway and Pine") |
| **Claude / any MCP client** | MCP over Streamable HTTP at `/mcp` | Address or coordinates |

Setup guides: [Siri Shortcut](docs/siri-shortcut.md) · [ChatGPT](docs/chatgpt.md) · [iPhone app with Siri App Intents](ios/README.md)

## Data

All data comes live from the City of Seattle's public ArcGIS services (no API key needed):

- [Parking Categories](https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/Parking_Categories/FeatureServer/0): one record per side of every block, with its category (paid, time limited, RPZ, unrestricted, no parking, carpool), paid hours and hourly rates by time of day, time limit, RPZ zone and weekday peak-hour tow-away windows.
- [Restricted Parking Zones](https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/Restricted_Parking_Zone_Areas/FeatureServer/4): RPZ boundaries with zone name and hours in effect.
- Spoken addresses are geocoded with the ArcGIS World Geocoder.

Rules are evaluated at the current Seattle time: paid parking outside its hours is reported as free, rush-hour tow-away blocks are excluded while active, and a block that becomes a tow-away zone soon has its usable time capped.

**Known gaps.** The city data doesn't include the hours for most "time limited" blocks or for RPZ visitor limits on individual blocks, so those answers say to check the sign. Temporary no-parking signs, special events and street cleaning aren't covered. Always check the posted signs.

## API

```
GET /api/here?lat=47.6239&lon=-122.3145
GET /api/here?address=Broadway%20and%20Pine
GET /api/nearby?lat=47.6239&lon=-122.3145&minMinutes=180&freeOnly=true
```

| Param | Endpoints | Meaning |
| --- | --- | --- |
| `lat`, `lon` | both | Location. Or use `address` instead. |
| `address` | both | Place in words; Seattle is assumed. |
| `permitZone` | both | Your RPZ permit zone, so blocks in that zone count as unlimited. |
| `minMinutes` | nearby | Only places where you can stay at least this long. |
| `freeOnly` | nearby | Only places that are free right now. |
| `radiusMeters` | nearby | Search radius, default 500, max 1500. |
| `limit` | nearby | Number of results, default 3, max 10. |
| `format=text` | both | Return just the spoken sentence as plain text. |

JSON responses always include `speech`. `/api/nearby` results also carry `distanceMeters`, `direction`, `point` and a walking-directions `mapsUrl`.

MCP tools (`POST /mcp`): `parking_rules_here` and `find_nearest_parking`, with the same parameters.

## Running it

```sh
npm install
npm test
API_KEY=some-long-random-string npm start   # listens on $PORT, default 3000
```

Siri and ChatGPT need to reach it over public HTTPS, so deploy it somewhere: the included `Dockerfile` runs on Fly.io, Render, Google Cloud Run, Azure Container Apps and similar. For a quick test from your phone, `npx cloudflared tunnel --url http://localhost:3000` gives you a temporary HTTPS URL.

Environment variables:

- `API_KEY`: if set, every request except `/`, `/healthz` and `/openapi.json` needs it, as an `X-API-Key` header, `Authorization: Bearer …`, or `?key=` (for MCP clients that only take a URL). Set this on any public deployment.
- `PORT`: listen port (default 3000).
- `PUBLIC_URL`: the public base URL to advertise in `/openapi.json` (defaults to the request's host).
