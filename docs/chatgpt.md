# ChatGPT setup

ChatGPT doesn't share your phone's GPS with tools, so in ChatGPT you say where you are ("I'm at 14th and Republican on Capitol Hill, where can I park for three hours?") and the tool geocodes it. For automatic location, use the [Siri Shortcut](siri-shortcut.md).

You need the server deployed at a public HTTPS URL (below, `https://parking.example.com`) with an `API_KEY` set.

## Option A: custom GPT with an Action (works in voice mode)

1. In ChatGPT, go to **Explore GPTs → Create → Configure**.
2. Name it "Seattle Parking". Instructions, for example:

   > You help the user with street parking in Seattle. When they ask about the parking rules where they are, call `parkingRulesHere`. When they ask where they can park, call `findNearestParking`, passing `minMinutes` if they say how long they need and `freeOnly` if they want free parking. Pass their location as `address` exactly as they describe it, or `lat`/`lon` if they give coordinates. Reply by reading the `speech` field, lightly shortened for voice. Remind them to check posted signs if they ask whether something is guaranteed.

3. Under **Actions → Create new action**, choose **Import from URL** and enter `https://parking.example.com/openapi.json`.
4. **Authentication → API Key → Custom**, header name `X-API-Key`, and paste your key.
5. Save it (visibility "Only me" is fine). On your phone, open the GPT and start voice mode.

## Option B: MCP connector

ChatGPT can also connect to the MCP endpoint (Settings → Apps & Connectors → Advanced → Developer mode, then create a connector). Use

```
https://parking.example.com/mcp?key=YOUR_API_KEY
```

with no authentication, since the key is in the URL. The tools are `parking_rules_here` and `find_nearest_parking`. The same URL works with Claude (Settings → Connectors → Add custom connector) and other MCP clients.
