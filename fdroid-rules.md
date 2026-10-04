# F-Droid publishing rules (learned the hard way)

Every rule here broke a real fdroiddata pipeline while getting Dejavu (a Firefox/Fenix fork,
`com.byarchitect.dejavu`, merge request fdroid/fdroiddata!50786) through F-Droid. Most of them
apply to any app; the Gecko section at the end is browser specific.

Golden rule: **copy what an accepted, similar app does, word for word**, then change only what
you must. For Gecko apps that is Fennec F-Droid (`metadata/org.mozilla.fennec_fdroid.yml` in
fdroiddata and the `relan/fennecbuild` scripts). Guessing from scripts instead of copying the
recipe cost several pipeline rounds.

---

## 1. How the pipeline works

- Your MR runs these jobs: `checkupdates`, `git redirect`, `fdroid lint`, `fdroid rewritemeta`,
  `schema validation`, `tools check scripts`, `fdroid build`, `check source code`, `check apk`.
- The pipeline runs **in your fork** (`<you>/fdroiddata`), so your fork's settings apply
  (job timeout, runners).
- `fdroid build` order on the server: clone source -> `sudo` -> `srclibs` -> `prebuild` ->
  **scanner** -> `build` -> find `output` APK. `prebuild` runs **before** the scan, so deleting
  files in `prebuild` removes them from the scan too.
- F-Droid **never ships the CI-built APK**. After merge, their own build server rebuilds it
  and signs it with F-Droid's key. CI is only proof for the reviewer.
- A `fdroid build` job that dies on the GitLab time limit is not a recipe failure, but reviewers
  cannot see that the recipe works. Prove it (see section 9).

## 2. Recipe file format (`metadata/<appid>.yml`)

- Field order is fixed (canonical). Build entry order:
  `versionName, versionCode, commit, timeout, sudo, output, srclibs, prebuild, scanignore,
  build, ndk`. Wrong order = `rewritemeta` failure.
- `commit:` must be a full 40-character hash that is **reachable on a branch or tag** of the
  source repo. If you rewrite history or force-push, the pinned commit vanishes and every build
  fails at checkout. Never rewrite history after F-Droid merges.
- `sudo`, `prebuild` and `build` are lists, but each list runs as **one shell**, joined with
  `; `. `export` in one line is visible in later lines of the same list, not in other lists.
- Use `$$name$$` to reference a srclib path (example: `$$rustup$$/rustup-init.sh`).
- `MaintainerNotes` has a **4000 character limit** (schema validation). Keep it short.
- A block scalar like `MaintainerNotes: |-` needs a **blank line after it** before the next key
  (for example `AutoUpdateMode:`), or `rewritemeta` complains.
- `UpdateCheckMode: None` if the repo has no version info F-Droid can read. Otherwise
  `checkupdates` fails with `Couldn't find any version information`. Fennec uses `None` too.
- `AutoUpdateMode: None` goes with it.
- `AntiFeatures`: only list what is really true. `NonFreeDep` must go once the F-Droid build
  links no non-free code. Keep e.g. `Tracking` if the app talks to tracking services.
- `timeout:` (seconds) is the limit on **F-Droid's build server**. The default is **7200 (2 h)**.
  Long builds must set it; Fennec sets `timeout: 36000`. This is separate from GitLab's limit.

## 3. `rewritemeta` (formatting) traps

`rewritemeta` re-serialises the file with `ruamel.yaml` and fails on any difference. It prints
the exact diff after `These are the formatting issues:`. **Apply that diff exactly.**

- ruamel wraps long values only at spaces, around column 80. A long list item like
  `- sed -i '...' some/very/long/path/file` gets split onto two lines and the job fails.
  **Keep every command line under ~72 characters.** Put paths in variables:
  `- export FAG=mobile/android/fenix/app/build.gradle` then `- sed -i '...' $FAG`.
- A value with no spaces cannot be wrapped. Whether ruamel puts it on the `key:` line or on the
  next line depends on its length and on the CI's ruamel version:
  - long `output:` path: CI wanted `output: ` + newline + indented path;
  - after shortening it (`.../release/*.apk`): CI wanted it **on one line**.
  Local checks with a different ruamel version did not reproduce this. Trust the CI diff.
- To check locally, use fdroidserver at the commit CI pins (see `.gitlab-ci.yml`) and
  `ruamel.yaml==0.18.14`, then run `fdroid rewritemeta <appid>` and `fdroid lint <appid>`.
  A clean local run is necessary but not sufficient.

## 4. Scanner (`fdroid build` scan step)

- The scanner reads **file text** (build.gradle lines, binary file magic), not the resolved
  dependency graph. So:
  - it flags non-free libs only when their catalog alias matches its regex
    (`com.google.android.gms`, `com.google.firebase`, `com.google.mlkit`,
    `com.android.installreferrer`, `com.google.android.play:review`, ...);
  - it does **not** catch everything: Adjust and Play Integrity, plus their transitive
    `play-services-basement/tasks`, passed the scanner. Always also check
    `gradle :app:dependencies --configuration releaseRuntimeClasspath` and the built APK
    (`aapt2 dump badging`, `aapt2 dump xmltree AndroidManifest.xml`).
- Errors that fail the build: `Found usual suspect`, `Found binary`, `Found ZIP file archive`
  (`.zip`, `.xpi`, `.jar`, `.apk`), `Found unknown maven repo`, `Found DexClassLoader`.
  Warnings (for example PDFs, some ZIPs) do not fail it.
- `scanignore:` = "do not scan this path". `scandelete:` = "delete this before scanning".
  Both fail with **`Unused scanignore path`** / **`Unused scandelete path`** /
  **`Non-exist scanignore path`** if nothing there matches. Remove unused entries.
- Only paths go in `scanignore`. A command (`rm -f ...`) put there by mistake gives
  `Unused scanignore path: rm -f ...`.
- If `scandelete` is present, F-Droid refuses to skip the scan.
- Do **not delete cargo-vendored crates** (`third_party/rust/...`): Cargo checks their
  checksums. `scanignore` them instead.
- Deleting a folder that a build file still lists breaks the build later (see section 7).
  Before `rm -rf` in `prebuild`, grep the build system for references. Prefer deleting only the
  flagged binaries (example: `rm -f $WE/*.xpi $WE/*.zip`) over whole folders.
- Run the scanner locally on a folder to check: `fdroidserver.scanner.scan_source(dir, Build())`
  (needs `puremagic` or `python-magic`).

## 5. Non-free code (inclusion policy)

- F-Droid builds must contain no closed-source libraries: Google Play services, Firebase,
  ML Kit, Play Review, Install Referrer, Play Integrity, Adjust, FIDO (`play-services-fido`), etc.
- Pattern that keeps the Play build unchanged: put non-free deps in a separate
  `proprietary.gradle`, applied only if it exists, and delete it in the recipe's `prebuild`
  (`rm -f .../proprietary.gradle`). Non-free code goes in `src/proprietary/java`, FOSS stand-ins
  in `src/foss/java`.
- Kotlin 2.4: `java.srcDirs` is ignored for `.kt` files. Use `kotlin.srcDirs` for Kotlin and
  `java.srcDirs` for Java.
- Remove leftovers from `src/main/AndroidManifest.xml` too (services, receivers, permissions,
  meta-data of removed SDKs), or they end up in the F-Droid APK.
- Add `dependenciesInfo { includeInApk = false; includeInBundle = false }` (Google's encrypted
  dependency blob is flagged).
- Do not let the app download executables without consent. Gecko example: OpenH264 / Widevine
  plugin downloads were turned off with prefs (`media.gmp-provider.enabled=false`, etc.).

## 6. `sudo` and the build environment

- The build server image is Debian trixie (`fdroidserver:buildserver-trixie`). It has
  `/opt/android-sdk`, `sdkmanager`, gradle, but **not** compilers or rust. Install everything
  in `sudo:` with `apt-get install -y ...`. Do not assume a tool exists.
- `openjdk-17` is not in trixie. Fennec adds a bookworm source and installs it with
  `-t bookworm`. Copying that exactly works; changing it to trixie broke the build.
- Missing pieces seen: `cc`/`clang` (`linker cc not found`), `rustup` (`command not found`),
  `terser`, `nodejs`, `nasm`, `python-is-python3`.
- Rust: use a `rustup` srclib and run `$$rustup$$/rustup-init.sh -y --default-toolchain X`,
  then `source $HOME/.cargo/env`. Rust host builds need
  `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang`.
- Never let the build tool call `su`/`sudo` itself (example: `mach bootstrap` tried
  `su root apt-get install watchman`). Disable auto-bootstrap.
- Android SDK pieces must be installed explicitly: `sdkmanager 'build-tools;X'`,
  `'platform-tools'`. **Minor-versioned platforms** (like `android-37.2`) cannot be installed by
  F-Droid's sdkmanager; download from `dl.google.com` and **verify the sha1 from Google's
  manifest** (`echo "$SHA1  $ZIP" | sha1sum -c`).
- Use the gradle F-Droid provides (`$(command -v gradle)`), never the gradle wrapper that
  downloads gradle.
- Nothing may be downloaded at build time without verification (npm installs, toolchains).
  Point tools at system packages instead (example: `terser` -> `/usr/bin/terser`).

## 7. Mozilla / Gecko specific

- `--disable-bootstrap`, `--disable-artifact-builds` (artifact builds download prebuilt Gecko,
  which F-Droid forbids), `--without-wasm-sandboxed-libraries`, explicit NDK `CC`/`CXX`/`STRIP`,
  `--with-gradle=$(command -v gradle)`, `--with-android-sdk`, `--with-android-ndk`.
- With bootstrap off, configure `die()`s on every missing SDK piece: build-tools, platform-tools,
  platform, `emulator` dir, cmdline-tools (`Android cmdline-tools X not found`), Bundletool
  (`ANDROID_BUNDLETOOL_PATH=/dev/null` works, only `mach install` uses it), `emulator` binary
  (`EMULATOR=/bin/true`).
- moz.build files are read even with `--disable-tests`: `TEST_DIRS` is skipped, but
  `PYTHON_UNITTEST_MANIFESTS`, `TEST_HARNESS_FILES` and plain `DIRS` are not. Deleting a test
  folder they reference fails config.status:
  - `OSError: Missing files: .../config/tests/python.toml`
  - `File listed in TEST_HARNESS_FILES does not exist: .../geckoview/src/androidTest/assets/...`
  Use `scanignore` for such folders, or delete only the flagged binaries inside them.
- `mach` needs `testing/mozbase` (`No module named 'mozfile'`): never delete it.
- `allWarningsAsErrors` must be off for the F-Droid toolchain; raise `mobile/android/gradle.py`
  wait time (`_seconds=600` -> `1800`) as Fennec does.
- Fenix builds **one APK per ABI** (`splits.abi`). Restrict to the ABI you compiled Gecko for,
  or the output pattern matches several APKs / none. Use a narrow sed; Fennec's
  `s/include ".*"/.../` also hit an unrelated `include "**/*.kt"` line in our build.gradle:
  `sed -i 's/include "armeabi-v7a", .*/include "arm64-v8a"/' $FAG`.
- The APK file name is **not** the same in every fork. Fennec's is `app-<abi>-release-unsigned.apk`;
  Dejavu's is `fenix-<abi>-release-unsigned.apk`. Check the real name (an existing local build
  or script) instead of copying it. Safest: `output: .../outputs/apk/release/*.apk` once only
  one ABI is built. Error when wrong: `No apks match ...`.
- Release version code: make sure the per-ABI version code equals the recipe's `versionCode`.

## 8. Resources and time limits

- GitLab SaaS runner (`saas-linux-medium-amd64`): 4 CPUs, 16 GB, **max 3 h** per job.
  A full Gecko + Fenix build needs about 3.5-5 h there. It reached `gkrust` after ~94 min and
  never finished. Fennec's own CI build is simply cancelled.
- A new fork has a **1 h** job timeout. Raise it (Settings -> CI/CD -> General pipelines ->
  Timeout, or API `build_timeout`).
- `gkrust` (the final Rust library) needs **more than 12 GB** of memory in a single `rustc`
  process. At a 12 GB container limit it was OOM-killed (`Memory cgroup out of memory: Killed
  process (rustc)`), which shows up only as `could not compile gkrust`. 14 GB + swap worked.
- Big browser repos can hit transient GitHub errors on clone (`The requested URL returned
  error: 500`). Retry before changing anything.

## 9. Running the pipeline on your own machine (self-hosted runner)

- fdroiddata's CI supports self-hosted runners for fork pipelines.
- Create a project runner on your fork (tag `saas-linux-medium-amd64`, run untagged = true),
  run `gitlab-runner` with the docker executor, and turn **off** instance runners on the fork
  so jobs go to your machine. Raise the fork timeout (example: 8 h).
- Limit the container (`cpuset_cpus`, `memory`, `memory_swap`) so the host survives, but give
  Gecko at least ~14 GB + swap. Stop other memory-hungry services (LLM servers, editors).
- On 10 CPUs the full build took ~1.5 h (versus >3 h on GitLab).
- The resulting green pipeline shows the self-hosted runner name; reviewers can see that.

## 10. Merge request workflow

- Keep the MR as **one commit** (`New app: <Name>`), amend and force-push to your fork branch.
- MR must not be **Draft** to be merged, and must be rebased if it is many commits behind.
- Never add `Co-Authored-By`/AI attribution lines to commits or MR text.
- Do not rewrite source history after the recipe pins a commit. If you must, rewrite only your
  own commits (a fork of mozilla-central also contains Mozilla commits with such lines;
  rewriting `--all` changes ~75k upstream hashes and breaks future upstream merges), then
  update `commit:` and the tag.

## 11. Checklist before every push

1. Every command line in `sudo`/`prebuild`/`build` under ~72 characters.
2. `fdroid rewritemeta` and `fdroid lint` clean locally (with CI's fdroidserver commit).
3. `MaintainerNotes` under 4000 characters, blank line after block scalars.
4. Every `scanignore`/`scandelete` path exists and is still needed.
5. Every `rm -rf` in `prebuild` checked against build-file references.
6. `output:` matches the **real** APK name, exactly one APK.
7. `commit:` reachable on the source repo, `versionCode` equals what the build produces.
8. Non-free check on resolved dependencies and the built APK, not just the scanner.
9. Fork timeout and runner memory enough for the build.

