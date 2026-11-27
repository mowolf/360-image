# In-app purchase: Pano 360 Unlimited

| Field | Value |
| --- | --- |
| Type | **Non-Consumable** |
| Reference name | Pano 360 Unlimited |
| Product ID | `com.moritzwolf.pano360.unlimited` (must match `Store.unlimitedID` in the app) |
| Price | 4,99 € (price point 4.99 USD/EUR; App Store Connect fills the other storefronts) |
| Family Sharing | optional – recommended "on" (no code changes needed) |

Model: **3 panoramas free**, then a one-time unlock for unlimited panoramas. Re-stitching an
existing capture is free. The gallery, viewer and sharing are never locked. The free counter is
stored in the Keychain, so it survives reinstalling.

## Set up in App Store Connect
1. **Agreements, Tax, and Banking**: the **Paid Apps** agreement must be active, with bank and tax
   forms filled in. Without it, StoreKit returns no products.
2. Your app → **Monetization → In-App Purchases → +** → *Non-Consumable*.
   - Reference name and product ID as above.
   - **Availability:** all countries.
   - **Price:** 4,99 €.
   - **App Store localization** (EN and DE, below).
   - **Review information:** a screenshot of the unlock card (camera screen after 3 panoramas)
     and the review notes below.
3. Submit the IAP **together with the app version**: in the version page under *In-App
   Purchases and Subscriptions*, select it. The first IAP must go with an app version.

### Localization
- **EN** – Display name: `Pano 360 Unlimited` · Description: `Create unlimited 360° panoramas. One-time purchase.`
- **DE** – Display name: `Pano 360 Unlimited` · Description: `Unbegrenzt 360°-Panoramen erstellen. Einmalkauf.`

### Review notes for the IAP
The first 3 panoramas are free. After the third, the camera screen shows an unlock card. The
purchase is restorable in Settings (grid button on the camera screen → gear icon → "Restore
purchases").

## Testing
- **TestFlight:** purchases use the sandbox automatically and cost nothing. To start over, delete
  the app, then clear the purchase history of the sandbox account in Settings → App Store →
  Sandbox Account. The free counter is in the Keychain: to reset it during testing, use a
  different device or a fresh install from the simulator.
- Restore: Settings → "Restore purchases" (calls `AppStore.sync()`).
