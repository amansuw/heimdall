# Releasing Heimdall

## One-time setup: in-app updates

Heimdall updates itself with [Sparkle](https://sparkle-project.org). Every update
is signed with an EdDSA private key, and the app refuses any update that does not
verify against the matching public key built into it.

Until both values below exist in the repository, releases still build and
publish, but with in-app updates switched off and no appcast.

Run these on your own Mac. The private key must never be pasted anywhere else.

1. Put Sparkle's tools on disk:

   ```sh
   xcodebuild -resolvePackageDependencies -project Heimdall.xcodeproj -clonedSourcePackagesDirPath build/SourcePackages
   ```

2. Create the key pair. The private key goes into your login keychain, and the
   command prints the public key:

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

3. Give the release workflow both halves: the public key as a repository
   variable, the private key as a secret.

   ```sh
   gh variable set SPARKLE_PUBLIC_KEY --body "PASTE-THE-PUBLIC-KEY-HERE"
   ```

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   ```

   ```sh
   gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key.txt
   ```

   ```sh
   rm sparkle-private-key.txt
   ```

**Back up the keychain item.** If the private key is lost, installed copies can
never accept another update; users would have to download a new build by hand.

## Each release

1. Tag the commit and push the tag:

   ```sh
   git tag v1.3
   ```

   ```sh
   git push origin v1.3
   ```

2. The Release workflow sets the version from the tag and the build number from
   the commit count, builds and signs the DMG, attests it, and — when updates are
   set up — signs the update and uploads `appcast.xml`. The app's feed is
   `releases/latest/download/appcast.xml`, so publishing the release is what
   offers the update.

3. Update `Casks/heimdall.rb`: set `version`, and set `sha256` from the
   release's `SHA256SUMS.txt`.

After updating, users are asked for their password once more the first time they
use fan control: the root helper only admits the exact build it was installed
from.
