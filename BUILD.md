# Building & installing on iPhone from Windows (no Mac)

You can't compile iOS apps on Windows, but you can build an `.ipa` in the cloud
and sideload it from Windows. End to end:

```
push to GitHub → GitHub Actions builds unsigned .ipa → Sideloadly signs + installs over USB
```

## 1. Push the project to GitHub

```powershell
cd "C:\Users\HP-IRIS\Desktop\Счетчик для IPhone"
git init
git add .
git commit -m "Fitness tracker"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

(Install Git for Windows first if needed: https://git-scm.com/download/win)

## 2. Build the .ipa in the cloud

The push triggers `.github/workflows/ios.yml` automatically — or run it manually
from the repo's **Actions** tab → **Build IPA** → **Run workflow**.

When it finishes (~3–5 min), open the run and download the
**FitnessTracker-ipa** artifact. Unzip it to get `FitnessTracker-unsigned.ipa`.

The runner uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) + `project.yml`
to generate the Xcode project, then builds **unsigned** (signing happens in step 3).

## 3. Install on your iPhone with Sideloadly (Windows)

1. Install **Sideloadly** (https://sideloadly.io) and **iTunes** (for the USB driver).
2. Plug in the iPhone, unlock it, tap **Trust**.
3. Drag `FitnessTracker-unsigned.ipa` into Sideloadly, enter your **Apple ID**, click **Start**.
   Sideloadly re-signs the app with your Apple ID and installs it.
4. On the phone: **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.
5. Launch the app and grant the camera prompt.

### Free Apple ID limits
- The app **expires after 7 days** — re-run Sideloadly to refresh it.
- Max 3 sideloaded apps at once.
- Device must be **iPhone XS or newer** (the app's compatibility check requires A12).

## Have a Mac instead?

Skip all of the above. Open the folder, run `xcodegen generate` (`brew install xcodegen`),
open `FitnessTracker.xcodeproj`, set your team under Signing & Capabilities, and press ⌘R.
