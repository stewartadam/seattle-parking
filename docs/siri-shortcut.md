# Siri setup (iOS Shortcuts)

Siri can run any Shortcut by its name, and a Shortcut can read your current location, so this is the hands-free option. You build two small Shortcuts once; after that, say "Hey Siri, parking here" or "Hey Siri, where can I park".

You need the server deployed at a public HTTPS URL (below, `https://parking.example.com`) and your `API_KEY`.

## "Parking here"

1. Open **Shortcuts**, tap **+**, and name it **Parking here**.
2. Add **Get Current Location**.
3. Add **Get Contents of URL** and set the URL to

   ```
   https://parking.example.com/api/here?format=text&lat=LAT&lon=LON
   ```

   Replace `LAT` with the **Current Location** variable, tap it, and choose **Latitude**. Do the same for `LON` with **Longitude**.
4. Expand **Get Contents of URL**, add a header `X-API-Key` with your key.
5. Add **Speak Text** with **Contents of URL** as the text.
6. Optional: if you have an RPZ permit, append `&permitZone=4` (your zone) to the URL.

The first run asks for permission to use your location and to contact your server; allow both.

## "Where can I park"

Duplicate the Shortcut, rename it **Where can I park**, and change the path from `/api/here` to `/api/nearby`.

Useful variations:

- **Need a few hours?** Add **Ask for Input** (Number, "How many minutes?") before the URL step and append `&minMinutes=` with that answer, so you only hear places with a long enough limit.
- **Free only:** append `&freeOnly=true`.
- **Open directions:** instead of plain text, drop `format=text`, then use **Get Dictionary Value** `speech` → **Speak Text**, and **Get Dictionary Value** `results` → **Get Item from List** (First Item) → **Get Dictionary Value** `mapsUrl` → **Open URLs** to start walking directions in Apple Maps.

## Tips

- Siri matches on the Shortcut name, so pick names you'll naturally say. You can add more trigger phrases by making extra Shortcuts that run this one.
- Add the Shortcut to your Home Screen, Lock Screen, Action button or CarPlay for one-tap use.
