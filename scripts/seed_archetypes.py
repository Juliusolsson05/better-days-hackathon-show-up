#!/usr/bin/env python3
"""Embed the archetype bios and load them into ClickHouse.

Run once, before clickhouse/002_seed.sql:
    pip install requests
    python scripts/seed_archetypes.py

These ~200 bios are the only text that is genuinely embedded. The million synthetic
profiles are generated around them inside ClickHouse, which is what keeps the seed to
200 API calls instead of a million -- and, more importantly, what makes the neighbours
in the vector space actually semantically related. A population of uniformly random
vectors has meaningless nearest neighbours, and the matches would not survive a judge
asking why two people were grouped together.
"""

import itertools
import json
import os
import sys

import requests

VOYAGE_KEY = os.environ["VOYAGE_API_KEY"]
CH_URL = os.environ["CLICKHOUSE_URL"]
CH_USER = os.environ["CLICKHOUSE_USER"]
CH_PASS = os.environ["CLICKHOUSE_PASSWORD"]

DIMS = 256  # must match voyage.ts and clickhouse/001_schema.sql

# (topic, tags, energy, first-person bio). Deliberately written the way a real user would
# answer "what are you passionate about" -- one or two sentences, specific, a bit odd.
TOPICS = [
    ("bouldering", ["climbing", "outdoors", "fitness"], "high",
     "I boulder four times a week and I've gotten obsessed with route reading -- standing "
     "at the bottom working out the sequence before I touch the wall."),
    ("shoegaze", ["music", "records", "concerts"], "calm",
     "I collect shoegaze and dream pop records. There's something about a wall of guitar "
     "that's mixed so the vocals are just another texture."),
    ("warhammer", ["painting", "tabletop", "miniatures"], "calm",
     "I paint Warhammer minis. Not for playing, mostly -- I just like the part where you "
     "spend six hours on a cloak."),
    ("baking sourdough", ["baking", "food", "fermentation"], "moderate",
     "I've kept the same sourdough starter alive for three years. I've named it. I talk "
     "about hydration percentages more than anyone wants."),
    ("urban cycling", ["cycling", "outdoors", "city"], "high",
     "I ride everywhere and I've started mapping the least-awful routes across the city. "
     "I have opinions about bike infrastructure."),
    ("film photography", ["photography", "analog", "art"], "calm",
     "I shoot film, mostly on a beat-up Canon AE-1. I like that you don't know what you got "
     "until weeks later."),
    ("competitive scrabble", ["wordgames", "competition", "strategy"], "moderate",
     "I play tournament Scrabble. Memorising the two-letter word list changed my life more "
     "than it should have."),
    ("birding", ["nature", "outdoors", "patience"], "calm",
     "I bird. Mostly shorebirds. I will stand in one spot for an hour and consider it a good day."),
    ("mechanical keyboards", ["making", "tech", "tinkering"], "moderate",
     "I build mechanical keyboards. I have lubed switches by hand while watching TV, which "
     "is either meditative or a warning sign."),
    ("improv", ["performance", "comedy", "social"], "high",
     "I do improv on Thursday nights. The whole skill is agreeing with whatever nonsense "
     "the other person just said."),
    ("chess", ["strategy", "games", "study"], "moderate",
     "I got back into chess and now I study endgames on the train. Rook and pawn endings, "
     "specifically, which nobody wants to hear about."),
    ("gardening", ["plants", "outdoors", "slow"], "calm",
     "I grow vegetables in a plot barely bigger than a parking space, and I am unreasonably "
     "invested in the tomatoes."),
    ("running", ["fitness", "outdoors", "endurance"], "high",
     "I run long and slow, usually before it's light out. It's the only hour of the day "
     "nobody wants anything from me."),
    ("anime", ["anime", "film", "stories"], "moderate",
     "I watch a lot of anime, mostly older stuff. I'll defend the pacing of slow shows to "
     "anyone who'll sit still."),
    ("pottery", ["making", "craft", "art"], "calm",
     "I throw pots. Badly, still, but the failure rate is part of it -- you can always wedge "
     "the clay back up and start over."),
    ("live music", ["music", "concerts", "nightlife"], "high",
     "I go to shows constantly, mostly small venues where you're standing three feet from "
     "the band."),
    ("hiking", ["outdoors", "nature", "walking"], "moderate",
     "I hike most weekends. Not summits particularly -- I'd rather do eight flat miles and "
     "actually look at things."),
    ("cooking", ["food", "cooking", "hosting"], "moderate",
     "I cook for people. The having-them-over is the point; the food is the excuse."),
    ("board games", ["games", "strategy", "social"], "moderate",
     "I host a board game night. Heavy euros, long setup, someone always leaves at midnight "
     "mid-game."),
    ("swimming", ["fitness", "water", "solitude"], "moderate",
     "I swim laps. It's the closest thing I have to not thinking."),
    ("writing", ["writing", "books", "solitude"], "calm",
     "I write short fiction that nobody reads, which honestly takes the pressure off."),
    ("thrifting", ["fashion", "vintage", "hunting"], "moderate",
     "I thrift obsessively. Most of my wardrobe belonged to a stranger and I like that."),
    ("astronomy", ["science", "night", "outdoors"], "calm",
     "I drive out of the city to look at things that are extremely far away. It resets "
     "something."),
    ("skateboarding", ["skating", "outdoors", "persistence"], "high",
     "I skate. I'm too old for it and I land maybe one trick in forty, but the one lands."),
    ("history podcasts", ["history", "learning", "listening"], "calm",
     "I listen to long history podcasts on walks. I know an alarming amount about the "
     "Byzantine Empire for someone with no use for it."),
]

# Each topic gets several phrasings so the embedding space has real local structure around
# it rather than a single point. 25 topics x 8 = 200 archetypes.
VARIANTS = [
    "", " I've been at it about two years now.",
    " It's the thing I'd talk about all night if someone let me.",
    " I got into it during a rough stretch and it stuck.",
    " I'm still bad at it and that's mostly fine.",
    " My friends are sick of hearing about it.",
    " I'd love to find people who take it as seriously as I do.",
    " I do it alone almost always, which is the part I'd like to change.",
]


def build_archetypes():
    rows = []
    for i, ((topic, tags, energy, bio), suffix) in enumerate(
        itertools.product(TOPICS, VARIANTS)
    ):
        rows.append({"id": i, "label": topic, "bio": bio + suffix,
                     "tags": tags, "energy": energy})
    return rows


def embed(texts):
    """input_type is null on purpose -- see the note in _shared/voyage.ts."""
    out = []
    for i in range(0, len(texts), 128):
        batch = texts[i:i + 128]
        res = requests.post(
            "https://api.voyageai.com/v1/embeddings",
            headers={"Authorization": f"Bearer {VOYAGE_KEY}"},
            json={"input": batch, "model": "voyage-4",
                  "input_type": None, "output_dimension": DIMS},
            timeout=120,
        )
        res.raise_for_status()
        out.extend(d["embedding"] for d in res.json()["data"])
        print(f"  embedded {len(out)}/{len(texts)}", file=sys.stderr)
    return out


def ch(sql, body=None):
    res = requests.post(
        CH_URL,
        headers={"X-ClickHouse-User": CH_USER, "X-ClickHouse-Key": CH_PASS},
        data=(sql if body is None else sql + "\n" + body).encode(),
        timeout=300,
    )
    if not res.ok:
        raise SystemExit(f"clickhouse {res.status_code}: {res.text}")
    return res.text


def main():
    archetypes = build_archetypes()
    print(f"embedding {len(archetypes)} archetype bios...", file=sys.stderr)
    vectors = embed([a["bio"] for a in archetypes])

    ch("TRUNCATE TABLE IF EXISTS archetypes")
    payload = "\n".join(
        json.dumps({**a, "embedding": v}) for a, v in zip(archetypes, vectors)
    )
    ch("INSERT INTO archetypes FORMAT JSONEachRow", payload)

    n = ch("SELECT count() FROM archetypes").strip()
    print(f"loaded {n} archetypes at {DIMS} dims", file=sys.stderr)
    print("next: run clickhouse/002_seed.sql", file=sys.stderr)


if __name__ == "__main__":
    main()
