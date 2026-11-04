# Setup: get Mirror onto your iPhone and iPad

You do this **once**. Everything works from Safari on your iPad. No Mac needed.

After setup, every time code is pushed to `main` (or you press **Run workflow**), a cloud Mac builds the app and sends it to TestFlight.

---

## Step 1 - Register the app IDs (5 min)

Go to **developer.apple.com/account** → **Certificates, Identifiers & Profiles** → **Identifiers**.

1. Press **+** → **App Groups** → Continue.
   - Description: `Mirror`
   - Identifier: `group.com.ariberko.mirror`
2. Press **+** → **App IDs** → **App** → Continue.
   - Description: `Mirror`
   - Bundle ID (Explicit): `com.ariberko.mirror`
   - Tick **App Groups** → Configure → pick `group.com.ariberko.mirror`.
3. Press **+** → **App IDs** → **App** → Continue again.
   - Description: `Mirror Broadcast`
   - Bundle ID (Explicit): `com.ariberko.mirror.broadcast`
   - Tick **App Groups** → Configure → pick `group.com.ariberko.mirror`.

> Want a different ID? Use your own everywhere and add a GitHub **variable** named `APP_BUNDLE_ID` with it (Step 4).

## Step 2 - Create the app in App Store Connect (2 min)

Go to **appstoreconnect.apple.com** → **Apps** → **+** → **New App**.

- Platform: **iOS**
- Name: anything free, for example `Mirror for Ari` (must be unique on the App Store)
- Primary language: English
- Bundle ID: `com.ariberko.mirror`
- SKU: `mirror`
- User access: Full access

## Step 3 - Make an API key (2 min)

In App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **+**.

- Name: `GitHub`
- Access: **Admin** (needed so the cloud Mac can create signing certificates)

Download the `.p8` file (you can only download it **once**). Write down:

- **Issuer ID** (top of the page)
- **Key ID** (in the row of the new key)

Also find your **Team ID**: developer.apple.com/account → **Membership details**.

## Step 4 - Add the secrets to GitHub (3 min)

Open github.com/ariberko/iPad-Mini-Mirror → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Add these four:

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your Team ID (10 characters) |
| `ASC_KEY_ID` | The Key ID |
| `ASC_ISSUER_ID` | The Issuer ID |
| `ASC_PRIVATE_KEY` | Open the `.p8` file in the Files app (or a text editor), copy **everything**, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

Only if you changed the bundle ID: on the **Variables** tab add `APP_BUNDLE_ID`.

## Step 5 - Build it

GitHub → **Actions** → **TestFlight** → **Run workflow** → pick the branch → **Run**.

It takes about 10 minutes. Then Apple processes it for another 5 to 15 minutes.

## Step 6 - Install on both devices

1. Install **TestFlight** from the App Store on your iPhone **and** iPad.
2. App Store Connect → your app → **TestFlight** → **Internal Testing** → **+** → make a group, add yourself.
3. Open TestFlight on each device → **Install**.

The first build may ask about "Export Compliance". The app already says it uses no special encryption, so it should skip this. If asked, choose **None of the algorithms mentioned above**.

---

## Using Mirror

1. Open **Mirror** on both devices. Allow **Local Network** when asked.
2. On the device you want to **show** (say iPhone), tap the other device under **Share This Screen**.
3. The first time, a code appears on the iPad. Type it on the iPhone.
4. Tap the big button, then **Start Broadcast**.
5. Your iPhone screen shows on the iPad, with sound.

It works both ways. To show the iPad on the iPhone, do the same steps the other way around.

**On the device that is showing the other screen:**

- **Tap** to show or hide controls.
- **Drag** photos or files onto the screen to send them. They land in the other device's **Inbox** (tray icon), with a notification.
- **Picture in Picture**: tap the PiP button or just swipe home.
- **X** stops mirroring on both devices.

---

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Devices don't see each other | Open Mirror on both. Turn Wi-Fi and Bluetooth on. Settings → Privacy → Local Network → Mirror on. |
| "Pairing code has changed" | Tap the device again and type the new code. |
| Black screen for one app | That app blocks recording (Netflix, banking apps). This is iOS, not Mirror. |
| Picture stops when iPhone locks | iOS pauses sharing on lock. Keep it unlocked, or raise Auto-Lock time. |
| TestFlight build fails at "Archive (signed)" | Check that the API key is **Admin** and the IDs in Step 1 exist. Send me the error and I'll fix it. |
| TestFlight build fails at "Upload" | Make sure the app exists in App Store Connect (Step 2) with the same bundle ID. |
