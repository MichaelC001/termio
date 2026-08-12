---
name: testflight-release
description: Ship a new TestFlight build of the iOS companion (TermioMobile) — resolve the next build number against App Store Connect, archive, sign, export, upload, write the What to Test notes, and distribute. Invoke when the user says 'ship a testflight build', 'update testflight', 'upload to testflight', 'new beta build', 'push the ios app to testers', '发一个 TestFlight', '更新 TestFlight', or '上传测试版'.
---

# TestFlight release (iOS companion)

Cuts a TestFlight build of `TermioMobile` by hand. Unlike the Mac app, **this is
not automated**: `.github/workflows` has no upload step, so nothing happens when
a PR merges. Every TestFlight build is a local archive + upload.

Use the `asc` skill for anything beyond this path (crash triage, App Store
submission, metadata). This skill is only the beta-build pipeline, with the
repo-specific facts that `asc` cannot know.

## Constants

| Thing | Value |
| --- | --- |
| App ID | `6790142237` (`sh.termio.mobile`, "Termio: Agentic Terminal") |
| Bundle ID resource | `97KQ9JGYL8` |
| Team | `5Y27G7B6D8`, from `ios/Signing.xcconfig` — **not** the project file |
| Internal group | `7b62f012-b166-40df-ba19-e43c3a0b2c88` |
| Public Beta group | `fe170244-643a-4c73-9c94-84ab44c254f9` (external, public link) |
| Signing assets | `~/Library/Developer/asc-signing/termio/` (mode 700, outside the repo) |

## The build number in the repo is a lie

`CURRENT_PROJECT_VERSION` in `ios/TermioMobile.xcodeproj/project.pbxproj` sits at
an old value (285 at the time of writing) while App Store Connect is in the
700s. That is deliberate: the bump is applied for the archive and then thrown
away.

**Never commit the bump.** Resolve it against ASC, build, upload, revert:

```sh
cd ios
asc xcode version edit --next-build-number --app 6790142237 --platform IOS \
    --project TermioMobile.xcodeproj --output json
# ... archive, export, upload ...
git checkout -- TermioMobile.xcodeproj/project.pbxproj
```

Uploading a build number at or below the highest one in ASC is rejected, so
never guess it from the repo.

## Steps

Run from a clean worktree on the commit you want to ship (normally `main`).

1. **Bump** — the command above. It reports the number it chose.

2. **Archive** (Release, signed for distribution):

   ```sh
   cd ios
   asc xcode archive \
     --project TermioMobile.xcodeproj --scheme TermioMobile \
     --configuration Release --clean \
     --archive-path .asc/artifacts/TermioMobile.xcarchive \
     --xcodebuild-flag=-destination --xcodebuild-flag=generic/platform=iOS \
     --xcodebuild-flag=-allowProvisioningUpdates --output json
   ```

3. **Export.** Automatic signing does *not* work on this Mac — Xcode's stored
   account token is broken (`missing Xcode-Token`), so `asc xcode export` fails
   with `No signing certificate "iOS Distribution" found`. Export manually
   against the profile instead, with `ios/.asc/ExportOptions.plist`:

   ```xml
   <key>method</key>                <string>app-store-connect</string>
   <key>teamID</key>                <string>5Y27G7B6D8</string>
   <key>signingStyle</key>          <string>manual</string>
   <key>signingCertificate</key>    <string>iPhone Distribution: Jiwei Yuan (5Y27G7B6D8)</string>
   <key>provisioningProfiles</key>  <dict><key>sh.termio.mobile</key><string>Termio iOS App Store</string></dict>
   ```

   ```sh
   xcodebuild -exportArchive \
     -archivePath .asc/artifacts/TermioMobile.xcarchive \
     -exportPath .asc/artifacts/export \
     -exportOptionsPlist .asc/ExportOptions.plist
   ```

   It still logs the `DVTDeveloperAccountManager` credential error; with manual
   signing that is noise, not a failure. Check for `** EXPORT SUCCEEDED **`.

4. **Upload** and wait for processing:

   ```sh
   asc builds upload --app 6790142237 --ipa .asc/artifacts/export/TermioMobile.ipa --wait
   ```

5. **What to Test** — required for external testers, good manners for internal:

   ```sh
   asc builds test-notes create --build-id "BUILD_ID" --locale en-US \
     --whats-new "..."
   ```

   Note the subcommand is `create`; `update` only edits notes that already
   exist. One paragraph, concrete, no AI attribution.

6. **Distribute.**
   - *Internal* needs no command. Internal groups pick up every processed build
     automatically — `asc builds add-groups` on the Internal group fails with
     "Cannot add internal group to a build." Confirm instead:
     `asc testflight distribution view --build-id "BUILD_ID"` → `Internal State:
     IN_BETA_TESTING`.
   - *Public Beta* is external: the build sits at `READY_FOR_BETA_SUBMISSION`
     until it passes Beta App Review. **Ask the user before submitting it** —
     that ships to real testers on a public link.

7. **Revert** the pbxproj bump and delete `ios/.asc/` (untracked build
   artifacts, ~10 MB IPA plus the archive).

## Signing assets

The account has one iOS Distribution certificate (`M92KPZPT43`, expires
2027-08-12) and the `Termio iOS App Store` profile (`R3N9335442`). Both were
created with the `asc` CLI, and the identity is installed in the login keychain.

If they are ever missing or expired, recreate them:

```sh
mkdir -p ~/Library/Developer/asc-signing/termio && chmod 700 ~/Library/Developer/asc-signing/termio
asc certificates create --certificate-type IOS_DISTRIBUTION --generate-csr \
  --key-out ./dist.key --csr-out ./dist.csr --common-name "Jiwei Yuan"
# save the base64 certificateContent from the response as dist.cer, then:
openssl x509 -inform DER -in dist.cer -out dist.pem
openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12 \
  -name "iOS Distribution: Jiwei Yuan"
security import dist.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
asc profiles create --name "Termio iOS App Store" --profile-type IOS_APP_STORE \
  --bundle 97KQ9JGYL8 --certificate "CERT_ID"
asc profiles download --id "PROFILE_ID" --output ./TermioAppStore.mobileprovision
asc profiles local install --path ./TermioAppStore.mobileprovision
```

`-legacy` is not optional: OpenSSL 3 defaults to a PKCS#12 MAC that macOS
cannot read, and `security import` fails with "MAC verification failed during
PKCS12 import (wrong password?)" — which looks like a password problem and is
not one.

Certificates are account-level and limited in number. Creating or revoking one
affects every machine that signs this app, so confirm with the user first.

## Notes

- The iOS app version is `1.0` and stays there; TestFlight builds move only the
  build number. Bumping the marketing version is an App Store release decision —
  see `docs/RELEASING.md` and the `asc` skill's release-flow reference.
- `ios/dev-run.sh` is the device-install loop for development; it has nothing to
  do with this path and never touches signing for distribution.
