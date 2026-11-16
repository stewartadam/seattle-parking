# Seattle Parking for iPhone (Siri App Intents)

A small iOS app that lets Siri answer parking questions using the phone's location, with no Shortcuts setup needed. It calls the same server as the Shortcuts (`/api/here`, `/api/nearby`).

| Say | What happens |
| --- | --- |
| "Parking rules here in Seattle Parking" | Reads the rules for both sides of the street you're on and shows a card. |
| "Find parking with Seattle Parking" | Reads the closest legal spots, then asks **"Want walking directions to the closest one?"** Saying yes opens Apple Maps. |
| "Directions to *[spot]* in Seattle Parking" | Opens walking directions to a spot from your last search. |

Other variations Siri recognizes: "Can I park here with Seattle Parking", "Where can I park with Seattle Parking", "Find a spot with Seattle Parking".

In Shortcuts, **Find Parking** also takes "Minutes needed" and "Free only", so you can build "find parking for 3 hours" style shortcuts.

## Build and install

Requires Xcode 16 or later, iOS 18 or later, and a paid or free Apple developer account.

```sh
brew install xcodegen
cd ios
xcodegen generate
open SeattleParking.xcodeproj
```

1. In Xcode, select the **SeattleParking** target, then go to **Signing & Capabilities**. Pick your team, and change the bundle ID from `com.example.seattleparking` to one of your own.
2. Plug in your iPhone, select it as the run destination, and press Run. If you haven't enabled Developer Mode on the phone, enable it under Settings › Privacy & Security.
3. In the app, enter your server URL (for example `https://parking.example.com`) and your API key. The app has no default server. Add your RPZ permit zone if you have one. Tap **Allow location access** and choose **While Using the App**.
4. Tap **Find parking** in the app to check that everything works, then try Siri.

Siri can take a minute after the first install to pick up the phrases. If Siri says it can't get your location, open the app once, or set Location to "Always" in Settings › Seattle Parking.

The API key is stored in the app's preferences on the phone.
