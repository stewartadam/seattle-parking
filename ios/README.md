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

1. In Xcode, select the **SeattleParking** target, then go to **Signing & Capabilities**. Pick your team. The bundle ID is `com.github.stewartadam.seattleparking`; change it if you build under a different account.
2. Plug in your iPhone, select it as the run destination, and press Run. If you haven't enabled Developer Mode on the phone, enable it under Settings › Privacy & Security.
3. The app opens Settings on first launch. Enter your server URL (for example `https://parking.example.com`) and your API key, then tap **Test connection**. The app has no default server. Add your RPZ permit zone if you have one.
4. Tap **Done**. Allow location access when asked (**While Using the App**). The main screen then shows the rules for the street you're on, and **Find parking** shows nearby spots on a map with walking directions. Then try Siri.

Siri can take a minute after the first install to pick up the phrases. If Siri says it can't get your location, open the app once, or set Location to "Always" in Settings › Seattle Parking.

The API key is stored in the app's preferences on the phone.

## CarPlay

On CarPlay the app shows Apple's parking map with up to 12 of the closest spots, pinned in the same colors as the phone's street map: green is free, yellow has restrictions, red is no parking. Choose a stay length with the button at the top left, and green-yellow then means the spot works for that stay. Tap a pin for its rules and a **Directions** button that opens Maps. **Search Here** searches wherever you've scrolled the map, and the location button searches around the car again.

CarPlay apps need an entitlement that Apple grants by hand. Request the **Parking** category at <https://developer.apple.com/contact/carplay/>. Once it's granted, uncomment `CODE_SIGN_ENTITLEMENTS: CarPlay.entitlements` in `project.yml`, regenerate the project and rebuild. Until then the app runs on the phone as before but doesn't appear in the car. Simulator builds always include the entitlement, so you can try it now: run in the iOS Simulator and open **I/O › External Displays › CarPlay**.
