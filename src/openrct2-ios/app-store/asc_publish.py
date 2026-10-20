#!/usr/bin/env python3
"""Publish the App Store metadata of OpenRCT2 for iOS to App Store Connect.

Source of truth, relative to src/openrct2-ios/app-store:

    app.json                                  # app-level settings (see below)
    locales/<folder>/metadata.json            # product-page copy, one folder per locale
    locales/<folder>/ipad/*.png               # iPad 13" screenshots, landscape 2752x2064
    locales/<folder>/iphone/*.png             # iPhone 6.9" screenshots, portrait 1320x2868
    release-notes/<version>/<folder>.txt      # What's New of one version (not for 1.0)

metadata.json:
    {
      "locale": "en-US",                # App Store Connect locale code
      "name": "...",                    # appInfoLocalization.name            (<=30)
      "subtitle": "...",                # appInfoLocalization.subtitle        (<=30)
      "privacyPolicyUrl": "...",        # appInfoLocalization.privacyPolicyUrl
      "promotionalText": "...",         # appStoreVersionLocalization         (<=170)
      "keywords": "...",                # appStoreVersionLocalization         (<=100)
      "description": "...",             # appStoreVersionLocalization         (<=4000)
      "supportUrl": "...",              # appStoreVersionLocalization
      "marketingUrl": "...",            # appStoreVersionLocalization
      "screenshotFallback": "en"        # optional folder whose screenshots are reused
    }

app.json: primaryLocale and contentRightsDeclaration (app), categories (appInfo),
ageRating (ageRatingDeclaration), releaseType (appStoreVersion), price and availability.
Entered by hand in App Store Connect and never read or written here (personal details stay out
of this public repository): the copyright line and App Review information. App Privacy
("Data Not Collected") has no public API and is also answered there.

Subcommands:
    validate    Local checks only (lengths, required fields, screenshot sizes); no credentials.
    inspect     Read-only: app, version, settings, localizations, screenshots.
    push-app    app.json: app, appInfo, age rating, release type, price, availability.
    push-text   Product-page copy and version-matched release notes.
    push-shots  Replace the screenshots of every locale and device.
    push-all    push-app, push-text, then push-shots.

Credentials (env): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (.p8 of an App Manager key).
Optional (env):
    ASC_VERSION_ID     pin a specific appStoreVersion id (else the latest editable one)
    ASC_LOCALES        space-separated subset of locale folders (else all)
    ASC_DEVICES        default "ipad iphone"
    ASC_DRY_RUN=1      print actions, perform no writes
    ASC_SKIP_WITHOUT_VERSION=1  succeed without publishing when no version is editable

The .p8 private key is a secret: pass it by path via ASC_KEY_PATH, never commit it.
"""
import argparse
import glob
import hashlib
import json
import os
import struct
import time

import jwt
import requests

ROOT = os.path.dirname(os.path.abspath(__file__))
BASE = "https://api.appstoreconnect.apple.com"
KEY_ID = os.environ.get("ASC_KEY_ID")
ISSUER = os.environ.get("ASC_ISSUER_ID")
KEY_PATH = os.environ.get("ASC_KEY_PATH")
FORCE_VERSION = os.environ.get("ASC_VERSION_ID")
LOCALES_DIR = os.path.join(ROOT, "locales")
RELEASE_NOTES_DIR = os.path.join(ROOT, "release-notes")
DRY = os.environ.get("ASC_DRY_RUN") == "1"
# Automatic runs (metadata pushed while no version is editable) end without an error.
SKIP_WITHOUT_VERSION = os.environ.get("ASC_SKIP_WITHOUT_VERSION") == "1"
DEVICES = (os.environ.get("ASC_DEVICES") or "ipad iphone").split()

# Device folder -> screenshotDisplayType and the accepted pixel sizes.
DEVICE_DISPLAY = {"ipad": "APP_IPAD_PRO_3GEN_129", "iphone": "APP_IPHONE_67"}
DEVICE_SIZES = {
    "ipad": {(2752, 2064), (2064, 2752), (2732, 2048), (2048, 2732)},
    "iphone": {(1320, 2868), (2868, 1320), (1290, 2796), (2796, 1290)},
}
LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotionalText": 170, "description": 4000}
REQUIRED = ("locale", "name", "subtitle", "privacyPolicyUrl", "promotionalText", "keywords",
            "description", "supportUrl")
WHATS_NEW_LIMIT = 4000
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "METADATA_REJECTED", "REJECTED",
    "DEVELOPER_REJECTED", "INVALID_BINARY", "PROCESSING_FOR_DISTRIBUTION",
}

_token_cache = {"t": None, "exp": 0}


def token():
    now = int(time.time())
    if _token_cache["t"] and now < _token_cache["exp"] - 60:
        return _token_cache["t"]
    with open(KEY_PATH) as f:
        key = f.read()
    t = jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
    )
    _token_cache["t"], _token_cache["exp"] = t, now + 1100
    return t


def req(method, path, ok404=False, **kw):
    url = path if path.startswith("http") else BASE + path
    headers = kw.pop("headers", {})
    headers.setdefault("Authorization", "Bearer " + token())
    for attempt in range(8):
        try:
            r = requests.request(method, url, headers=headers, timeout=120, **kw)
        except (requests.exceptions.SSLError,
                requests.exceptions.ConnectionError,
                requests.exceptions.Timeout) as e:
            if attempt == 7:
                raise SystemExit(f"\nConnection failed after retries: {method} {url}\n{e}\n")
            time.sleep(1.5 * (attempt + 1))
            continue
        if r.status_code == 429:
            time.sleep(2 ** attempt)
            continue
        if ok404 and r.status_code == 404:
            return None
        if r.status_code >= 400:
            raise SystemExit(f"\nAPI {method} {url} -> {r.status_code}\n{r.text}\n")
        return r
    raise SystemExit(f"API {method} {url}: rate-limited after retries")


def get_json(path, params=None, ok404=False):
    r = req("GET", path, ok404=ok404, params=params)
    return r.json() if r is not None else None


def get_all(path, params=None):
    out = []
    data = get_json(path, params=params)
    out += data.get("data", [])
    nxt = data.get("links", {}).get("next")
    while nxt:
        data = get_json(nxt)
        out += data.get("data", [])
        nxt = data.get("links", {}).get("next")
    return out


def write(method, path, body, action):
    """Every write goes through here so a dry run prints it instead."""
    if DRY:
        print("DRY", action)
        return None
    r = req(method, path, json=body)
    print("OK  ", action)
    return r.json() if r is not None and r.content else None


# ---------- local metadata ----------

def load_app():
    with open(os.path.join(ROOT, "app.json"), encoding="utf-8") as f:
        return json.load(f)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"Not a PNG: {path}")
    return struct.unpack(">II", head[16:24])


def load_locales(only=None):
    locales = []
    for folder in sorted(os.listdir(LOCALES_DIR)):
        if only and folder not in only:
            continue
        meta_path = os.path.join(LOCALES_DIR, folder, "metadata.json")
        if not os.path.exists(meta_path):
            continue
        with open(meta_path, encoding="utf-8") as f:
            m = json.load(f)
        m["folder"] = folder
        missing = [k for k in REQUIRED if not m.get(k)]
        if missing:
            raise SystemExit(f"{meta_path}: missing {missing}")
        for field, limit in LIMITS.items():
            if len(m[field]) > limit:
                raise SystemExit(f"{meta_path}: {field} is {len(m[field])} chars (>{limit} limit)")
        fallback = m.get("screenshotFallback")
        if fallback == folder:
            raise SystemExit(f"{meta_path}: screenshotFallback cannot reference itself")
        m["screenshotFolder"] = fallback or folder
        m["screenshotDir"] = os.path.join(LOCALES_DIR, m["screenshotFolder"])
        if not os.path.isdir(m["screenshotDir"]):
            raise SystemExit(f"{meta_path}: screenshot folder does not exist: {m['screenshotDir']}")
        for device in DEVICES:
            for path in screenshot_files(m, device):
                if png_size(path) not in DEVICE_SIZES[device]:
                    raise SystemExit(f"{path}: {png_size(path)} is not a {device} App Store size")
        locales.append(m)
    if only:
        missing = [o for o in only if o not in {l["folder"] for l in locales}]
        if missing:
            raise SystemExit(f"No metadata.json for requested locales: {missing}")
    if not locales:
        raise SystemExit(f"No locale folders with metadata.json under {LOCALES_DIR}")
    return locales


def screenshot_files(locale, device):
    return sorted(glob.glob(os.path.join(locale["screenshotDir"], device, "*.png")))


def load_release_notes(locales, version):
    """What's New of the selected version. A first version has none; once a directory for the
    version exists, every selected locale needs a non-empty file."""
    root = os.path.join(RELEASE_NOTES_DIR, version["attributes"]["versionString"])
    if not os.path.isdir(root):
        print(f"release notes: none at {root}; remote whatsNew is unchanged")
        return None
    missing = []
    for m in locales:
        path = os.path.join(root, f"{m['folder']}.txt")
        if not os.path.isfile(path):
            missing.append(path)
            continue
        with open(path, encoding="utf-8") as f:
            note = f.read().strip()
        if not note or len(note) > WHATS_NEW_LIMIT:
            raise SystemExit(f"{path}: whatsNew must be 1-{WHATS_NEW_LIMIT} chars")
        m["whatsNew"] = note
    if missing:
        raise SystemExit("Missing release notes:\n  " + "\n  ".join(missing))
    print(f"release notes: loaded {len(locales)} locales from {root}")
    return root


# ---------- discovery ----------

def find_app(bundle_id):
    apps = [a for a in get_all("/v1/apps", {"filter[bundleId]": bundle_id, "limit": 200})
            if a["attributes"]["bundleId"] == bundle_id]
    if not apps:
        raise SystemExit(f"No app with bundleId {bundle_id}; create the app record in App Store Connect first")
    a = apps[0]
    print(f"App: {a['attributes']['name']}  ({bundle_id})  id={a['id']}")
    return a


def ver_state(v):
    at = v["attributes"]
    return at.get("appStoreState") or at.get("appVersionState") or "?"


def find_version(app_id):
    vers = get_all(f"/v1/apps/{app_id}/appStoreVersions", {"limit": 50})
    print("\nappStoreVersions:")
    for v in vers:
        at = v["attributes"]
        print(f"  - id={v['id']}  version={at.get('versionString')}  "
              f"platform={at.get('platform')}  state={ver_state(v)}")
    if FORCE_VERSION:
        match = [v for v in vers if v["id"] == FORCE_VERSION]
        if not match:
            raise SystemExit(f"ASC_VERSION_ID {FORCE_VERSION} not found")
        return match[0]
    editable = [v for v in vers if ver_state(v) in EDITABLE_STATES and v["attributes"].get("platform") == "IOS"]
    if not editable:
        message = ("No editable iOS appStoreVersion. This tool never creates a version; "
                   "create one in App Store Connect first, or set ASC_VERSION_ID.")
        if SKIP_WITHOUT_VERSION:
            print(f"::notice::{message} Nothing was published.")
            raise SystemExit(0)
        raise SystemExit(message)
    editable.sort(key=lambda v: (v["attributes"].get("createdDate") or "",
                                 v["attributes"].get("versionString") or ""), reverse=True)
    v = editable[0]
    print(f"\n-> editable version: id={v['id']} version={v['attributes'].get('versionString')} "
          f"state={ver_state(v)}")
    return v


def find_appinfo(app_id):
    infos = get_all(f"/v1/apps/{app_id}/appInfos", {"limit": 50})
    for i in infos:
        st = i["attributes"].get("appStoreState") or i["attributes"].get("state")
        if st in EDITABLE_STATES or st is None:
            return i["id"]
    return infos[0]["id"] if infos else None


def version_locs(version_id):
    return {l["attributes"]["locale"]: l for l in
            get_all(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", {"limit": 50})}


def appinfo_locs(appinfo_id):
    return {l["attributes"]["locale"]: l for l in
            get_all(f"/v1/appInfos/{appinfo_id}/appInfoLocalizations", {"limit": 50})}


# ---------- app-level settings ----------

def push_app(app, appinfo_id, version, cfg):
    app_id = app["id"]
    write("PATCH", f"/v1/apps/{app_id}",
          {"data": {"type": "apps", "id": app_id, "attributes": {
              "primaryLocale": cfg["primaryLocale"],
              "contentRightsDeclaration": cfg["contentRightsDeclaration"]}}},
          f"PATCH app primaryLocale={cfg['primaryLocale']} "
          f"contentRightsDeclaration={cfg['contentRightsDeclaration']}")

    cats = cfg["categories"]
    rel = {key: {"data": {"type": "appCategories", "id": cats[key]} if cats.get(key) else None}
           for key in ("primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo",
                       "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo")}
    write("PATCH", f"/v1/appInfos/{appinfo_id}",
          {"data": {"type": "appInfos", "id": appinfo_id, "relationships": rel}},
          "PATCH appInfo categories " + ", ".join(f"{k}={v}" for k, v in cats.items() if v))

    push_age_rating(appinfo_id, cfg["ageRating"])

    write("PATCH", f"/v1/appStoreVersions/{version['id']}",
          {"data": {"type": "appStoreVersions", "id": version["id"], "attributes": {
              "releaseType": cfg["releaseType"]}}},
          f"PATCH appStoreVersion releaseType={cfg['releaseType']}")

    push_price(app_id, cfg["price"])
    push_availability(app_id, cfg["availability"])


def push_age_rating(appinfo_id, answers):
    decl = get_json(f"/v1/appInfos/{appinfo_id}/ageRatingDeclaration")["data"]
    remote = decl["attributes"]
    unknown = [k for k in answers if k not in remote]
    if unknown:
        raise SystemExit(f"app.json ageRating has keys App Store Connect does not know: {unknown}\n"
                         f"Known keys: {sorted(remote)}")
    unanswered = [k for k, v in remote.items() if v is None and k not in answers]
    if unanswered:
        print(f"NOTE age rating questions left unanswered: {unanswered}")
    write("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}",
          {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": answers}},
          f"PATCH ageRatingDeclaration ({len(answers)} answers)")


def push_price(app_id, price):
    """A single manual price in the base territory, which App Store Connect equalizes elsewhere."""
    territory = price["baseTerritory"]
    points = get_all(f"/v1/apps/{app_id}/appPricePoints",
                     {"filter[territory]": territory, "limit": 200})
    wanted = [p for p in points if float(p["attributes"]["customerPrice"]) == float(price["customerPrice"])]
    if not wanted:
        raise SystemExit(f"No {territory} price point of {price['customerPrice']}")
    write("POST", "/v1/appPriceSchedules",
          {"data": {"type": "appPriceSchedules", "relationships": {
              "app": {"data": {"type": "apps", "id": app_id}},
              "baseTerritory": {"data": {"type": "territories", "id": territory}},
              "manualPrices": {"data": [{"type": "appPrices", "id": "${price}"}]}}},
           "included": [{"type": "appPrices", "id": "${price}", "attributes": {"startDate": None},
                         "relationships": {"appPricePoint": {"data": {
                             "type": "appPricePoints", "id": wanted[0]["id"]}}}}]},
          f"POST appPriceSchedule {territory} {price['customerPrice']}")


def push_availability(app_id, availability):
    territories = [t["id"] for t in get_all("/v1/territories", {"limit": 200})]
    excluded = set(availability.get("excludedTerritories", []))
    existing = get_json(f"/v1/apps/{app_id}/appAvailabilityV2", ok404=True)
    existing = existing and existing.get("data")
    if not existing:
        included = [{"type": "territoryAvailabilities", "id": f"${{{t}}}",
                     "attributes": {"available": t not in excluded},
                     "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                    for t in territories]
        write("POST", "/v2/appAvailabilities",
              {"data": {"type": "appAvailabilities",
                        "attributes": {"availableInNewTerritories": availability["availableInNewTerritories"]},
                        "relationships": {
                            "app": {"data": {"type": "apps", "id": app_id}},
                            "territoryAvailabilities": {"data": [
                                {"type": "territoryAvailabilities", "id": i["id"]} for i in included]}}},
               "included": included},
              f"POST appAvailability ({len(territories) - len(excluded)} of {len(territories)} territories)")
        return
    changes = 0
    for ta in get_all(f"/v2/appAvailabilities/{existing['id']}/territoryAvailabilities",
                      {"limit": 200, "include": "territory"}):
        territory = ta["relationships"]["territory"]["data"]["id"]
        wanted = territory not in excluded
        if ta["attributes"].get("available") != wanted:
            changes += 1
            write("PATCH", f"/v1/territoryAvailabilities/{ta['id']}",
                  {"data": {"type": "territoryAvailabilities", "id": ta["id"],
                            "attributes": {"available": wanted}}},
                  f"PATCH territoryAvailability {territory} available={wanted}")
    print(f"availability: {changes} territories changed")


# ---------- text ----------

def push_text(appinfo_id, version, locales):
    version_id = version["id"]
    existing_v = version_locs(version_id)
    existing_i = appinfo_locs(appinfo_id)
    print(f"\nexisting version locales: {sorted(existing_v)}")
    print(f"existing appInfo locales: {sorted(existing_i)}")
    for m in locales:
        loc = m["locale"]
        vattrs = {k: m[k] for k in ("description", "keywords", "promotionalText", "supportUrl")}
        vattrs["marketingUrl"] = m.get("marketingUrl")
        if "whatsNew" in m:
            vattrs["whatsNew"] = m["whatsNew"]
        if loc in existing_v:
            lid = existing_v[loc]["id"]
            write("PATCH", f"/v1/appStoreVersionLocalizations/{lid}",
                  {"data": {"type": "appStoreVersionLocalizations", "id": lid, "attributes": vattrs}},
                  f"PATCH appStoreVersionLocalization {loc} ({', '.join(vattrs)})")
        else:
            write("POST", "/v1/appStoreVersionLocalizations",
                  {"data": {"type": "appStoreVersionLocalizations", "attributes": {**vattrs, "locale": loc},
                            "relationships": {"appStoreVersion": {"data": {
                                "type": "appStoreVersions", "id": version_id}}}}},
                  f"POST appStoreVersionLocalization {loc}")

        iattrs = {k: m[k] for k in ("name", "subtitle", "privacyPolicyUrl")}
        if loc not in existing_i and not DRY:
            # Creating a version localization can also create the appInfo one; refresh so a
            # stale snapshot does not cause a duplicate-locale 409.
            existing_i = appinfo_locs(appinfo_id)
        if loc in existing_i:
            lid = existing_i[loc]["id"]
            write("PATCH", f"/v1/appInfoLocalizations/{lid}",
                  {"data": {"type": "appInfoLocalizations", "id": lid, "attributes": iattrs}},
                  f"PATCH appInfoLocalization {loc} ({', '.join(iattrs)})")
        else:
            write("POST", "/v1/appInfoLocalizations",
                  {"data": {"type": "appInfoLocalizations", "attributes": {**iattrs, "locale": loc},
                            "relationships": {"appInfo": {"data": {"type": "appInfos", "id": appinfo_id}}}}},
                  f"POST appInfoLocalization {loc}")


# ---------- screenshots ----------

def screenshot_set(version_loc_id, display_type):
    for s in get_all(f"/v1/appStoreVersionLocalizations/{version_loc_id}/appScreenshotSets", {"limit": 50}):
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"]
    if DRY:
        print(f"DRY would create appScreenshotSet {display_type}")
        return "DRY_SET"
    return req("POST", "/v1/appScreenshotSets",
               json={"data": {"type": "appScreenshotSets",
                              "attributes": {"screenshotDisplayType": display_type},
                              "relationships": {"appStoreVersionLocalization": {"data": {
                                  "type": "appStoreVersionLocalizations",
                                  "id": version_loc_id}}}}}).json()["data"]["id"]


def clear_set(set_id):
    if set_id == "DRY_SET":
        return
    for s in get_all(f"/v1/appScreenshotSets/{set_id}/appScreenshots", {"limit": 50}):
        if DRY:
            print(f"DRY would delete appScreenshot {s['id']}")
        else:
            req("DELETE", f"/v1/appScreenshots/{s['id']}")
            print(f"     deleted old screenshot {s['id']}")


def upload_one(set_id, path):
    with open(path, "rb") as f:
        data = f.read()
    resv = req("POST", "/v1/appScreenshots",
               json={"data": {"type": "appScreenshots",
                              "attributes": {"fileSize": len(data), "fileName": os.path.basename(path)},
                              "relationships": {"appScreenshotSet": {"data": {
                                  "type": "appScreenshotSets", "id": set_id}}}}}).json()["data"]
    sid = resv["id"]
    for op in resv["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        hdrs = {h["name"]: h["value"] for h in (op.get("requestHeaders") or [])}
        for attempt in range(6):
            try:
                rr = requests.request(op["method"], op["url"], data=chunk, headers=hdrs, timeout=300)
                rr.raise_for_status()
                break
            except requests.exceptions.RequestException:
                if attempt == 5:
                    raise
                time.sleep(1.5 * (attempt + 1))
    req("PATCH", f"/v1/appScreenshots/{sid}",
        json={"data": {"type": "appScreenshots", "id": sid,
                       "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return sid


def push_shots(version, locales):
    existing_v = version_locs(version["id"])
    for m in locales:
        loc = m["locale"]
        if loc not in existing_v and not DRY:
            print(f"SKIP {loc}: version localization missing; run push-text first")
            continue
        for device in DEVICES:
            files = screenshot_files(m, device)
            if not files:
                print(f"SKIP {loc}/{device}: no PNGs in {m['screenshotDir']}/{device}")
                continue
            display_type = DEVICE_DISPLAY[device]
            print(f"\n[{loc}/{device}] {len(files)} screenshots (source={m['screenshotFolder']}) -> {display_type}")
            if loc not in existing_v:
                print(f"DRY would create the {loc} localization's set and upload {len(files)} files")
                continue
            set_id = screenshot_set(existing_v[loc]["id"], display_type)
            clear_set(set_id)
            ids = []
            for f in files:
                if DRY:
                    print(f"DRY would upload {os.path.basename(f)}")
                    continue
                ids.append(upload_one(set_id, f))
                print(f"     uploaded {os.path.basename(f)} (id={ids[-1]})")
            if ids:
                req("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
                    json={"data": [{"type": "appScreenshots", "id": i} for i in ids]})
                print(f"     ordered {len(ids)} screenshots")


# ---------- inspect ----------

def inspect(app, appinfo_id, version, locales, cfg):
    at = app["attributes"]
    print(f"\napp: primaryLocale={at.get('primaryLocale')} "
          f"contentRightsDeclaration={at.get('contentRightsDeclaration')}  "
          f"(local: {cfg['primaryLocale']}, {cfg['contentRightsDeclaration']})")
    va = version["attributes"]
    print(f"version: releaseType={va.get('releaseType')}  (local: {cfg['releaseType']})")
    print(f"         copyright set: {bool(va.get('copyright'))}  (entered in App Store Connect)")
    info = get_json(f"/v1/appInfos/{appinfo_id}", {"include": "primaryCategory,primarySubcategoryOne,"
                    "primarySubcategoryTwo,secondaryCategory"})["data"]["relationships"]
    remote_cats = {k: (v.get("data") or {}).get("id") for k, v in info.items() if "ategory" in k}
    print(f"categories: {remote_cats}  (local: {cfg['categories']})")
    decl = get_json(f"/v1/appInfos/{appinfo_id}/ageRatingDeclaration")["data"]["attributes"]
    diff = {k: (decl.get(k), v) for k, v in cfg["ageRating"].items() if decl.get(k) != v}
    unknown = [k for k in cfg["ageRating"] if k not in decl]
    print(f"age rating: {len(diff)} answers differ {diff if diff else ''}")
    if unknown:
        print(f"  local keys unknown to App Store Connect: {unknown}\n  remote keys: {sorted(decl)}")
    review = get_json(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail", ok404=True)
    review = (review or {}).get("data")
    print(f"review detail: {'present' if review else 'missing'}  (entered in App Store Connect)")

    ev = version_locs(version["id"])
    ei = appinfo_locs(appinfo_id)
    target = [m["locale"] for m in locales]
    print(f"\nversion-loc locales : {sorted(ev)}")
    print(f"appInfo-loc locales : {sorted(ei)}")
    print(f"missing version-loc : {[l for l in target if l not in ev]}")
    print(f"missing appInfo-loc : {[l for l in target if l not in ei]}")
    print("\ntext (MATCH/DIFF per field):")
    for m in locales:
        loc = m["locale"]
        fields = []
        for src, keys in ((ev, ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl",
                                "whatsNew")), (ei, ("name", "subtitle", "privacyPolicyUrl"))):
            remote = src.get(loc, {}).get("attributes", {})
            for k in keys:
                if k in m:
                    fields.append(k if (remote.get(k) or "").strip() == m[k].strip() else k + "*")
        print(f"  {loc}: {' '.join(fields)}   (* = differs)")
    print("\nscreenshots:")
    for m in locales:
        loc = m["locale"]
        local = ", ".join(f"{d}={len(screenshot_files(m, d))}" for d in DEVICES)
        if loc not in ev:
            print(f"  {loc}: (no version localization)  local[{local}; source={m['screenshotFolder']}]")
            continue
        sets = get_all(f"/v1/appStoreVersionLocalizations/{ev[loc]['id']}/appScreenshotSets", {"limit": 50})
        desc = ", ".join(
            f"{s['attributes']['screenshotDisplayType']}="
            f"{len(get_all('/v1/appScreenshotSets/' + s['id'] + '/appScreenshots', {'limit': 50}))}"
            for s in sets) or "(none)"
        print(f"  {loc}: remote[{desc}]  local[{local}; source={m['screenshotFolder']}]")
    print("\nApp Privacy has no public API: answer \"Data Not Collected\" once in App Store Connect.")


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["validate", "inspect", "push-app", "push-text", "push-shots", "push-all"])
    args = ap.parse_args()

    cfg = load_app()
    only = os.environ.get("ASC_LOCALES")
    locales = load_locales(only.split() if only else None)
    print("locale folders:", [f"{m['folder']}->{m['locale']}" for m in locales])
    if args.cmd == "validate":
        print("Local metadata is valid.")
        return
    if not (KEY_ID and ISSUER and KEY_PATH):
        raise SystemExit("Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH env vars.")

    app = find_app(cfg["bundleId"])
    version = find_version(app["id"])
    appinfo_id = find_appinfo(app["id"])
    print(f"appInfo id={appinfo_id}")
    if args.cmd != "push-shots":
        load_release_notes(locales, version)

    if args.cmd == "inspect":
        inspect(app, appinfo_id, version, locales, cfg)
        return
    if args.cmd in ("push-app", "push-all"):
        print("\n==== PUSH APP SETTINGS ====")
        push_app(app, appinfo_id, version, cfg)
    if args.cmd in ("push-text", "push-all"):
        print("\n==== PUSH TEXT ====")
        push_text(appinfo_id, version, locales)
    if args.cmd in ("push-shots", "push-all"):
        print("\n==== PUSH SCREENSHOTS ====")
        push_shots(version, locales)
    print("\nDone." + ("  (DRY RUN — no writes)" if DRY else ""))


if __name__ == "__main__":
    main()
