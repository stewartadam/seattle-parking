# Seattle Parking for iPhone (Siri App Intents)

A small iOS app that lets Siri answer parking questions using the phone's location, with no Shortcuts setup and no server needed.

The app keeps a copy of the City of Seattle's street parking data on the phone (about 46,000 block sides, about a 3 MB download and 10 MB on disk) and refreshes it every week, so answers work without a connection. It downloads the copy on first launch, and the first question waits for that download. Your location never leaves the phone. The parking rules are a Swift port of the server's `src/parking.js`, in `SeattleParking/Parking/`, and give the same answers.

Answers are kept short because you're probably driving: Siri says only the closest street (no cross streets) and its rules, and the card on screen shows the rest.

| Say | What happens |
| --- | --- |
| "Parking rules here in Seattle Parking" | Says the rules on the street you're on and shows a card with both sides. |
| "Find parking with Seattle Parking" | Says the closest legal spot, shows a few more on a card, then asks **"Want directions?"** Saying yes opens Apple Maps. If you can park right where you are, Siri just says so. |
| "Find parking for two hours with Seattle Parking" | The same, but only spots where you can stay that long. Siri understands one hour, two hours, four hours and overnight ("Find overnight parking", "Find parking until morning"). |
| "Find parking until a certain time with Seattle Parking" | Siri asks "Until when?" and understands answers like "9 AM tomorrow". |
| "Find parking near a place with Seattle Parking" | Siri asks "Near where?" and looks up the answer ("Lighthouse Coffee Roasters") with Apple Maps, limited to Seattle. Also works with a stay: "Find overnight parking near a place". |

Other variations Siri recognizes: "Can I park here with Seattle Parking", "Where can I park with Seattle Parking", "Find a spot with Seattle Parking", "Where can I park overnight with Seattle Parking".

Siri phrases can only hold values from a fixed list, which is why a time like "until 9 AM tomorrow" or a place name takes a second question. "Overnight" means until 8 AM the next morning. A stay past midnight is checked against the next day's rules too, so a block that turns into a rush-hour tow-away zone in the morning is left out.

In Shortcuts, **Find Parking** also takes "Staying for" and "Free only", and **Find Parking Until a Time** takes any time.

## Build and install

Requires Xcode 16 or later, iOS 18.2 or later, and a paid or free Apple developer account.

```sh
brew install xcodegen
cd ios
xcodegen generate
open SeattleParking.xcodeproj
```

1. In Xcode, select the **SeattleParking** target, then go to **Signing & Capabilities**. Pick your team. The bundle ID is `com.github.stewartadam.seattleparking`; change it if you build under a different account.
2. Plug in your iPhone, select it as the run destination, and press Run. If you haven't enabled Developer Mode on the phone, enable it under Settings › Privacy & Security.
3. Allow location access when asked (**While Using the App**). If you have an RPZ permit, add its zone in Settings (the gear icon).
4. The main screen then shows the rules for the street you're on, and **Find parking** shows nearby spots on a map with walking directions. Then try Siri.

Siri can take a minute after the first install to pick up the phrases. If Siri says it can't get your location, open the app once, or set Location to "Always" in Settings › Seattle Parking.

Settings also shows when the city data was last updated, with an **Update Now** button.

## Tests

The parking rules have unit tests in `SeattleParkingTests/`. They check the same cases as the server's tests in `test/`, using the same recorded Capitol Hill data, so the app and the server keep giving the same answers.

GitHub runs them automatically on every pull request that touches `ios/`, in an iPhone simulator, and shows a green check or a red cross on the pull request. Nothing needs setting up.

To run them yourself on the Mac:

1. Generate and open the project as above (`xcodegen generate`, then `open SeattleParking.xcodeproj`).
2. At the top of the Xcode window, set the run destination to any iPhone simulator (for example **iPhone 17**), not your phone.
3. Choose **Product › Test** (or press Command-U). The simulator opens briefly while they run.
4. Open the Test navigator (the diamond icon in the left sidebar, or Command-6) to see each test with a green or red mark.

If you change a rule in `src/parking.js`, change the Swift copy in `SeattleParking/Parking/` too, and add a test on both sides.

## CarPlay

On CarPlay the app shows Apple's parking map with up to 12 of the closest spots, pinned in the same colors as the phone's street map: green is free, yellow has restrictions, red is no parking. Choose a stay length with the button at the top left, and green-yellow then means the spot works for that stay. Tap a pin for its rules and a **Directions** button that opens Maps. **Search Here** searches wherever you've scrolled the map, and the location button searches around the car again.

CarPlay apps need an entitlement that Apple grants by hand. Request the **Parking** category at <https://developer.apple.com/contact/carplay/>. Once it's granted, uncomment `CODE_SIGN_ENTITLEMENTS: CarPlay.entitlements` in `project.yml`, regenerate the project and rebuild. Until then the app runs on the phone as before but doesn't appear in the car. Simulator builds always include the entitlement, so you can try it now: run in the iOS Simulator and open **I/O › External Displays › CarPlay**.
