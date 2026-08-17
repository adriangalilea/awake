# awake — one state machine for keep-awake, menu bar + CLI.
#
#   make            build the binary (release)
#   make check      compile everything, debug — the FAST typecheck (must be 0 warnings)
#   make install    build + install binary, asleep symlink, launchd agent; restart daemon
#   make uninstall  remove binary, symlink, launchd agent (sudoers grant: `awake grant --remove`)
#   make clean      remove the build directory
#   make notes      draft notes/$(VERSION).md from the commits (you then rewrite it)
#   make release    signed, notarized, stapled dmg → tag → GitHub Release → cask
#   make publish    dmg → R2 behind awake.untitled.garden/releases (the COUNTED url) + notes → garden (release does this)
#   make cask       bump the Homebrew cask to the built dmg (release does this)
#   make icon       redraw Resources/awake.icns + icon.png from scripts/make-icon.swift

BIN := .build/release/awake
NOTIFIER_BIN := .build/release/awake-notifier
ICON := Resources/awake.icns
LABEL := garden.untitled.awake
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
PREFIX ?= $(HOME)/.local
# The .app bundle exists for ONE reason: UNUserNotificationCenter refuses unbundled
# processes. Assembled by hand (no Xcode), ad-hoc signed, lives in ~/Applications.
# The CLI is a symlink into the bundle so daemon and CLI stay ONE binary.
APP := $(HOME)/Applications/awake.app
APPBIN := $(APP)/Contents/MacOS/awake

# THE VERSION, single source of truth: it stamps Info.plist and names the tag.
# A mac app has a native version field, so the manifest is truth here and the
# tag is derived from it (the inverse of a Swift library, where the tag IS the
# version because SwiftPM has no manifest field).
VERSION := 0.3.0

DIST := dist
RELEASE_APP := $(DIST)/awake.app
DMG := $(DIST)/awake-$(VERSION).dmg
NOTES := notes/$(VERSION).md

# The Homebrew tap holding the cask recipe. A separate repo because Homebrew
# only discovers taps by the `homebrew-` name prefix, so it can never live here.
TAP ?= $(HOME)/Developer/homebrew-tap
# The untitled garden monorepo: its release tool is the ONE writer to the R2
# bucket behind <slug>.untitled.garden/releases/<file>, the download URL that is
# COUNTED (garden KPI `download`), and `pnpm garden notes` syncs notes/<v>.md
# to the surface's release rows. The cask points at that URL, never at GitHub,
# so every brew install is a counted download. A fork without the checkout
# skips both and its downloads simply go unmeasured.
GARDEN ?= $(HOME)/Developer/untitled

# Discovered, never hardcoded, so a fork signs with its own certificate. Empty
# on a machine with no Developer ID: `install` falls back to ad-hoc, `release`
# refuses.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | \
	sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)

# A keychain profile, so no notary identifier and no key path exists in this
# repo or in any file. Create it once:
#   xcrun notarytool store-credentials awake \
#     --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#     --key-id <KEYID> --issuer <ISSUER-UUID>
NOTARY_PROFILE ?= awake

# THE BUILD MUTEX: concurrent `make` invocations serialize instead of fighting over
# .build. A lock older than 10 minutes is stale (a killed make) and gets stolen.
LOCK := $(patsubst %/,%,$(or $(TMPDIR),/tmp))/awake-build.lock
define ACQUIRE
while ! mkdir "$(LOCK)" 2>/dev/null; do \
  if [ -n "$$(find "$(LOCK)" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$(LOCK)" 2>/dev/null || true; \
  else sleep 2; fi; \
done; trap 'rmdir "$(LOCK)" 2>/dev/null' EXIT
endef

# Bundle assembly, used by BOTH install and release so the app you run and the
# app you ship can never diverge. $(1) = destination .app
# The notifier is a second, nested .app (Contents/Helpers/awake-notifier.app): the
# notification hop needs an LS-launched user-context app, and the daemon is a launchd
# agent by design. Same icon, own bundle id, its own Info.plist.
define ASSEMBLE
mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Resources"; \
ditto "$(BIN)" "$(1)/Contents/MacOS/awake"; \
ditto "$(ICON)" "$(1)/Contents/Resources/awake.icns"; \
sed "s|__VERSION__|$(VERSION)|g" launchd/Info.plist.in > "$(1)/Contents/Info.plist"; \
mkdir -p "$(1)/Contents/Helpers/awake-notifier.app/Contents/MacOS" "$(1)/Contents/Helpers/awake-notifier.app/Contents/Resources"; \
ditto "$(NOTIFIER_BIN)" "$(1)/Contents/Helpers/awake-notifier.app/Contents/MacOS/awake-notifier"; \
ditto "$(ICON)" "$(1)/Contents/Helpers/awake-notifier.app/Contents/Resources/awake.icns"; \
sed "s|__VERSION__|$(VERSION)|g" launchd/Notifier-Info.plist.in > "$(1)/Contents/Helpers/awake-notifier.app/Contents/Info.plist"
endef

.PHONY: build check install uninstall clean notes release publish cask icon

build:
	@$(ACQUIRE); swift build -c release

check:
	@$(ACQUIRE); swift build > /dev/null && echo "awake: 0 errors, 0 warnings"

# The web surface wants the flat PNG too, so both fall out of one script.
$(ICON) Resources/icon.png: scripts/make-icon.swift
	@swift scripts/make-icon.swift

icon: $(ICON)

install: build $(ICON)
	@mkdir -p "$(PREFIX)/bin" "$(HOME)/Library/Logs/awake"
	@$(call ASSEMBLE,$(APP))
	@# Developer ID gives a STABLE identity — TCC ties notification permission to the
	@# signature, and ad-hoc identities churn every rebuild (UNErrorDomain Code=1).
	@# Falls back to ad-hoc on machines without the cert.
	@# Inner first, then outer: a nested app must carry its own signature before the
	@# enclosing bundle is sealed over it. Notification permission is tied to the
	@# NOTIFIER's identity, so a stable Developer ID matters most on that one.
	@codesign --force --sign "$(or $(SIGN_ID),-)" "$(APP)/Contents/Helpers/awake-notifier.app"
	@codesign --force --sign "$(or $(SIGN_ID),-)" "$(APP)"
	@# CLI = symlinks into the bundle: Bundle.main resolves through them, so the CLI
	@# shares the daemon's defaults domain (hotkey remaps land where the daemon reads).
	@ln -sf "$(APPBIN)" "$(PREFIX)/bin/awake"
	@ln -sf "$(APPBIN)" "$(PREFIX)/bin/asleep"
	@# The Claude skill ships with the app (_core skills convention: symlinked dir,
	@# editing the repo updates the live skill).
	@mkdir -p "$(HOME)/.claude/skills"
	@ln -sfn "$(CURDIR)/skill" "$(HOME)/.claude/skills/awake"
	@echo "installed $(APP) (+ awake, asleep symlinks, claude skill)"
	@# The binary owns the launchd agent, not this Makefile: a cask's postflight
	@# installs it the same way, and one implementation cannot drift from itself.
	@"$(APPBIN)" agent install

uninstall:
	@if [ -x "$(APPBIN)" ]; then "$(APPBIN)" agent uninstall; \
	else launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true; fi
	@rm -rf "$(APP)"
	@rm -f "$(PLIST)" "$(PREFIX)/bin/awake" "$(PREFIX)/bin/asleep"
	@echo "removed app, symlinks, launchd agent. Sudoers grant: sudo rm /etc/sudoers.d/awake"

clean:
	@rm -rf .build $(DIST)

# THE WORDS GATE: a release exists only once a human has written what changed.
# git-cliff DRAFTS from the commits; the draft is raw material, not prose users
# read. Rewrite it, commit it, and that file is the release notes forever.
notes:
	@command -v git-cliff >/dev/null || { echo "git-cliff missing: brew install git-cliff"; exit 1; }
	@test ! -f "$(NOTES)" || { echo "$(NOTES) exists already — edit it"; exit 1; }
	@mkdir -p notes
	@git-cliff --config .github/cliff.toml --unreleased --tag "$(VERSION)" -o "$(NOTES)"
	@echo "drafted $(NOTES) — REWRITE it for humans, then commit it"

# Notarization is a credentialed act, so releasing is a LOCAL command: the
# certificate is in this keychain and the notary key is in ~/.appstoreconnect,
# neither of which belongs in CI. CI's job is the 0-warning gate, nothing more.
release: check build $(ICON)
	@test -z "$$(git status --porcelain)" || { echo "working tree is dirty"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { echo "tag $(VERSION) exists — bump VERSION"; exit 1; }
	@test -f "$(NOTES)" || { echo "no $(NOTES) — run 'make notes', then write it"; exit 1; }
	@# The grammar, checked HERE rather than by whoever renders it later: notes
	@# publish as DESIGNED releases (a glyph per group), so a body without groups
	@# and items renders as a dated heading with nothing underneath.
	@grep -q '^### ' "$(NOTES)" && grep -q '^- ' "$(NOTES)" || \
		{ echo "$(NOTES) needs '### Added|Fixed|Changed|Performance|Polish' sections with '- ' items"; exit 1; }
	@test -n "$(SIGN_ID)" || { echo "no 'Developer ID Application' certificate in the keychain"; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 || \
		{ echo "no notary keychain profile '$(NOTARY_PROFILE)' — see the Makefile header"; exit 1; }
	@rm -rf "$(DIST)" && mkdir -p "$(DIST)/stage"
	@$(call ASSEMBLE,$(RELEASE_APP))
	@# Hardened runtime + secure timestamp: notarization rejects anything less.
	@codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(RELEASE_APP)/Contents/Helpers/awake-notifier.app"
	@codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(RELEASE_APP)"
	@ditto -c -k --keepParent "$(RELEASE_APP)" "$(DIST)/awake.zip"
	@xcrun notarytool submit "$(DIST)/awake.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@# The REAL verdict: stapling fails unless a ticket was actually issued, so
	@# this is the check, not notarytool's exit status.
	@xcrun stapler staple "$(RELEASE_APP)"
	@cp -R "$(RELEASE_APP)" "$(DIST)/stage/" && ln -sf /Applications "$(DIST)/stage/Applications"
	@hdiutil create -volname awake -srcfolder "$(DIST)/stage" -ov -format UDZO "$(DMG)" -quiet
	@git tag -a "$(VERSION)" -m "$(VERSION)" && git push origin "$(VERSION)"
	@gh release create "$(VERSION)" --title "$(VERSION)" --notes-file "$(NOTES)" "$(DMG)"
	@$(MAKE) --no-print-directory publish
	@$(MAKE) --no-print-directory cask
	@echo "released $(VERSION): $(DMG)"

# The garden half of a release: the dmg behind the counted download URL, the
# notes on the surface. Publish BEFORE the cask bump: the cask's URL is this
# one, and brew fetches it the moment the tap updates.
publish:
	@test -f "$(DMG)" || { echo "no $(DMG) — run 'make release'"; exit 1; }
	@if [ ! -d "$(GARDEN)/tools/release" ]; then echo "no garden at $(GARDEN), skipping publish (downloads uncounted)"; exit 0; fi
	@url=$$(pnpm --dir "$(GARDEN)/tools/release" exec tsx dmg.ts awake "$(CURDIR)/$(DMG)") && echo "published $$url"
	@cd "$(GARDEN)" && pnpm --silent garden notes awake

# The cask points at the release asset by URL + sha256, so it can only be bumped
# once the dmg is public. A fork without the tap checked out just skips it.
cask:
	@test -f "$(DMG)" || { echo "no $(DMG) — run 'make release'"; exit 1; }
	@if [ ! -d "$(TAP)/.git" ]; then echo "no tap at $(TAP), skipping cask bump"; exit 0; fi
	@sha=$$(shasum -a 256 "$(DMG)" | cut -d' ' -f1); \
	sed -i '' \
		-e "s|^  version .*|  version \"$(VERSION)\"|" \
		-e "s|^  sha256 .*|  sha256 \"$$sha\"|" \
		"$(TAP)/Casks/awake.rb"; \
	git -C "$(TAP)" add Casks/awake.rb; \
	git -C "$(TAP)" commit -q -m "awake $(VERSION)"; \
	git -C "$(TAP)" push -q origin main; \
	echo "cask bumped to $(VERSION) ($$sha)"
