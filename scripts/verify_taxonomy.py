"""Validate the venue classifier against the full real vocabulary.

    python scripts/verify_taxonomy.py

Reads clickhouse/taxonomy_tree.csv -- every root/leaf pair in the SF slice, 1,231 of them --
and reports what is_social() admits and rejects, so the decision surface is reviewable as
data rather than trusted as code.

This exists because three hand-curated versions of the classifier were each wrong in ways
nobody noticed until a query came back odd: a gardening store and a ballet academy admitted,
every climbing gym in the city missing. A list that long cannot be checked by reading it.
The sanity assertions at the bottom are the ones that would have caught each of those.
"""
import csv, importlib.util, os
from collections import defaultdict

for k in ("VOYAGE_API_KEY", "CLICKHOUSE_URL", "CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD"):
    os.environ.setdefault(k, "x")
spec = importlib.util.spec_from_file_location("iv", os.path.join(os.path.dirname(__file__), "ingest_venues.py"))
iv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iv)

rows = list(csv.DictReader(open(os.path.join(os.path.dirname(__file__), "..", "clickhouse", "taxonomy_tree.csv"))))
inc, exc = defaultdict(int), defaultdict(int)
inc_leaves, excluded_in_social = [], []

for r in rows:
    root, leaf, n = r["root"], r["leaf"], int(r["n"])
    if iv.is_social(root, leaf):
        inc[root] += n
        inc_leaves.append((leaf, n))
    else:
        exc[root] += n
        if root in iv.SOCIAL_ROOTS:
            excluded_in_social.append((root, leaf, n))

total_in, total_out = sum(inc.values()), sum(exc.values())
print(f"ADMITTED {total_in} of {total_in + total_out} places\n")
print("by root:")
for root in sorted(inc, key=lambda r: -inc[r]):
    print(f"   {root:<26} {inc[root]:6d} in   {exc.get(root, 0):5d} out")

print(f"\nexcluded from WITHIN a social root ({len(excluded_in_social)} leaves, "
      f"{sum(n for _, _, n in excluded_in_social)} places):")
for root, leaf, n in sorted(excluded_in_social, key=lambda x: -x[2])[:14]:
    print(f"   {n:5d}  {root}/{leaf}")

print("\nsanity -- these MUST be admitted:")
for leaf in ("rock_climbing_spot", "cocktail_bar", "music_venue", "bowling_alley",
             "art_gallery", "beach", "ramen_restaurant", "escape_room"):
    hit = next((r for r in rows if r["leaf"] == leaf), None)
    ok = hit and iv.is_social(hit["root"], leaf)
    print(f"   {'OK ' if ok else 'MISSING'}  {leaf}")

print("\nsanity -- these must NOT be admitted:")
for leaf in ("gym", "dental_clinic", "hair_salon", "attorney_or_law_firm",
             "christian_place_of_worship", "playground", "historic_site", "dance_studio"):
    hit = next((r for r in rows if r["leaf"] == leaf), None)
    bad = hit and iv.is_social(hit["root"], leaf)
    print(f"   {'LEAKED' if bad else 'OK    '}  {leaf}")
