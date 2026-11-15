"""Upload verified Davao Region destination photos to Cloudinary and update Neon Postgres."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
from pathlib import Path

import asyncpg
import cloudinary
import cloudinary.uploader
import httpx
from dotenv import load_dotenv

CANDIDATES_DIR = Path(
    r"C:\Users\lozad\.gemini\antigravity\brain\93c83847-78d5-4369-bbcd-50c42f8a23d5\scratch\davao_candidates"
)
MANIFEST_OUT = CANDIDATES_DIR.parent / "all_41_cloudinary_urls.json"

CURATED_FILE_BY_ID: dict[int, str] = {
    4: "4b_samal_island.jpg",
    7: "7b_panabo_night.jpg",
    8: "8_tagbibinta_real_1.jpg",
    9: "9_mainit_hot_springs.jpg",
    10: "10e_kaputian_beach_1.jpg",
    11: "29_sleeping_dinosaur.jpg",
    12: "12_tudaya_falls.jpg",
    16: "16_aqua_water_park.jpg",
    19: "19_panabo_mangrove.jpg",
    20: "20_christ_king_tagum.jpg",
    21: "21d_dgt_central_park.jpg",
    22: "22_caraga_church.jpg",
    23: "23b_digos_rizal_sta_cruz.jpg",
    25: "25_new_barili_maco.jpg",
    26: "26_pyalitan_falls.jpg",
    27: "27_lake_leonard.jpg",
    28: "28_davao_occidental_sea.jpg",
    29: "29c_don_marcelino_bobon.jpg",
    30: "30_pasig_islet_davao_sur.jpg",
    31: "31_malagos_garden.jpg",
    32: "32_casas_con_vistas.jpg",
    33: "33_dbone_museum.jpg",
    34: "34_monfort_bat.jpg",
    35: "35_bukid_amara.jpg",
    36: "36_calamba_farm_og.jpg",
    37: "37_mt_hamiguitan.jpg",
    38: "38_bemwa_kape.jpg",
    39: "39_dahican_surf.jpg",
    40: "40_isla_reta.jpg",
    41: "41_urayas_peak.jpg",
}


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def _normalize_dsn(raw_url: str) -> str:
    dsn = raw_url.replace("postgresql+asyncpg://", "postgresql://")
    dsn = dsn.replace("postgresql+psycopg://", "postgresql://")
    return dsn


async def main() -> None:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    load_dotenv(env_path)

    cloudinary.config(
        cloud_name=os.environ["CLOUDINARY_CLOUD_NAME"],
        api_key=os.environ["CLOUDINARY_API_KEY"],
        api_secret=os.environ["CLOUDINARY_API_SECRET"],
        secure=True,
    )

    dsn = _normalize_dsn(os.environ["DATABASE_URL"])
    conn = await asyncpg.connect(dsn)
    try:
        rows = await conn.fetch(
            "SELECT destination_id, name, location, image_url FROM destinations ORDER BY destination_id"
        )
        by_id = {row["destination_id"]: dict(row) for row in rows}

        # Verify all local files exist before mutating
        for dest_id, filename in CURATED_FILE_BY_ID.items():
            if dest_id not in by_id:
                raise KeyError(f"Destination ID {dest_id} not found in Neon database.")
            fp = CANDIDATES_DIR / filename
            if not fp.is_file():
                raise FileNotFoundError(f"Missing curated image for ID {dest_id}: {fp}")

        # Fix Santo Niño mojibake on ID 41 if present
        row41 = by_id.get(41)
        if row41 and "NiÃ±o" in (row41.get("location") or ""):
            fixed_loc = row41["location"].replace("NiÃ±o", "Niño")
            await conn.execute(
                "UPDATE destinations SET location = $1, updated_at = NOW() WHERE destination_id = 41",
                fixed_loc,
            )
            print(f"Fixed ID 41 location -> {fixed_loc}")

        for dest_id, filename in sorted(CURATED_FILE_BY_ID.items()):
            fp = CANDIDATES_DIR / filename
            name = by_id[dest_id]["name"]
            short_hash = hashlib.sha1(fp.read_bytes()).hexdigest()[:8]
            public_id = f"{_slug(name)}-{short_hash}"
            res = cloudinary.uploader.upload(
                str(fp),
                folder=f"lakbay/destinations/{dest_id}",
                public_id=public_id,
                resource_type="image",
                overwrite=True,
                transformation=[{"width": 1280, "crop": "limit", "quality": "auto:good"}],
            )
            secure_url = res["secure_url"]
            await conn.execute(
                "UPDATE destinations SET image_url = $1, updated_at = NOW() WHERE destination_id = $2",
                secure_url,
                dest_id,
            )
            print(f"[{dest_id}] {name} -> {secure_url}")

        final_rows = await conn.fetch(
            "SELECT destination_id, name, location, category, image_url FROM destinations WHERE is_active = true ORDER BY destination_id"
        )
        manifest = [dict(r) for r in final_rows]
    finally:
        await conn.close()

    # Verify HTTP 200 on all active destination image_urls
    async with httpx.AsyncClient(timeout=15) as client:
        for item in manifest:
            url = item["image_url"]
            if not url or not url.startswith("https://res.cloudinary.com/"):
                raise RuntimeError(f"Invalid URL for {item['destination_id']}: {url}")
            r = await client.head(url)
            if r.status_code != 200:
                raise RuntimeError(f"HTTP {r.status_code} for {item['destination_id']}: {url}")

    MANIFEST_OUT.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Verified all {len(manifest)} destinations with HTTP 200 Cloudinary URLs.")
    print(f"Saved manifest -> {MANIFEST_OUT}")


if __name__ == "__main__":
    asyncio.run(main())
