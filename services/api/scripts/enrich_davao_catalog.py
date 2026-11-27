"""Idempotent Admin API enrichment CLI for verified Davao Region destinations (D6).

Default mode is ``--dry-run``: fetches live catalog state (or ``--offline``
fixture), validates all curated payloads against real Pydantic schemas and
``data_quality.py``, performs ``GET``-before-``PUT`` preservation checks, and
prints a non-secret diff summary without mutating production.

Use ``--apply`` with ``LAKBAY_ADMIN_EMAIL`` and ``LAKBAY_ADMIN_PASSWORD`` set
in the environment to execute authenticated Admin API writes.

Examples (run from ``services/api/``):
    ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --dry-run
    ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --dry-run --offline
    ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --apply
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx

from app.features.destinations.data_quality import data_quality
from app.features.destinations.schemas import (
    DestinationActivitiesUpdate,
    DestinationHoursUpdate,
    DestinationPricesUpdate,
    DestinationUpdate,
)

DEFAULT_API_BASE_URL = "https://lakbay-api-rioi.onrender.com/api/v1"
VERIFIED_AT = datetime(2026, 11, 27, 4, 45, 0, tzinfo=timezone.utc)
ARRIVAL_GUARD_FIELDS = frozenset({
    "arrival_lat",
    "arrival_lng",
    "arrival_source_url",
    "arrival_verified_at",
    "route_ready",
})
WIKIMEDIA_USER_AGENT = (
    "LakbayCatalogEnricher/1.0 (https://lakbay-api-rioi.onrender.com; D6 catalog curation)"
)


@dataclass(frozen=True)
class ImageSpec:
    """Verified CC/PD image staged for upload via POST /destinations/{id}/image."""

    file_title: str
    commons_page_url: str
    direct_url: str
    mime_type: str
    license_name: str
    author: str
    size_bytes: int


@dataclass(frozen=True)
class StagedClipSpec:
    """Verified Wikimedia Commons GIF/video clip staged for post-migration M5A."""

    target_destination_id: int
    target_name: str
    media_type: str
    file_title: str
    commons_page_url: str
    direct_url: str
    mime_type: str
    license_name: str
    author: str
    raw_size_bytes: int
    raw_duration_seconds: float
    requires_trim_transcode: bool
    ffmpeg_command: str | None
    notes: str


@dataclass(frozen=True)
class DestinationEnrichmentPlan:
    """Curated, source-grounded enrichment bundle for one destination."""

    destination_id: int
    name: str
    source_urls: tuple[str, ...]
    source_type: str
    patch_fields: dict[str, Any] = field(default_factory=dict)
    explicit_clear_fields: frozenset[str] = frozenset()
    hours_payload: dict[str, Any] | None = None
    prices_payload: dict[str, Any] | None = None
    activities_payload: dict[str, Any] | None = None
    image_spec: ImageSpec | None = None
    fields_kept_null: tuple[str, ...] = ()
    notes: str = ""


def _daily_weekly(
    opens_at: str,
    closes_at: str,
    *,
    closed_weekdays: frozenset[int] = frozenset(),
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for weekday in range(7):
        if weekday in closed_weekdays:
            rows.append({"weekday": weekday, "is_closed": True})
        else:
            rows.append({
                "weekday": weekday,
                "is_closed": False,
                "opens_at": opens_at,
                "closes_at": closes_at,
            })
    return rows


# ---------------------------------------------------------------------------
# Curated verified Davao Region enrichment plans (no fabricated fields)
# ---------------------------------------------------------------------------

ENRICHMENT_PLANS: tuple[DestinationEnrichmentPlan, ...] = (
    # --- Priority 3: Flagship structured upgrades (IDs 1..22) ----------------
    DestinationEnrichmentPlan(
        destination_id=1,
        name="People's Park",
        source_urls=(
            "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/",
        ),
        source_type="official_lgu",
        patch_fields={
            "operating_hours": "Monday - Sunday: 1:00 PM - 10:00 PM",
            "operating_status": "open",
            "booking_requirement": "not_required",
            "how_to_get_there": (
                "Located along J. Palma Gil Street, Poblacion District, Davao City; "
                "reachable by taxi or jeepney (via R. Castillo St.)."
            ),
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": (
                "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/"
            ),
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("13:00:00", "22:00:00"),
            "exceptions": [],
        },
        prices_payload={
            "fees_source_url": (
                "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/"
            ),
            "fees_verified_at": VERIFIED_AT,
            "prices": [
                {
                    "item": "entrance",
                    "audience": "everyone",
                    "amount": Decimal("0.00"),
                    "unit": "per_person",
                    "note": "Free public entrance listed by Davao City Tourism; bag inspection at gate.",
                },
            ],
        },
        activities_payload={
            "activities": [
                {
                    "name": "Walking & Jogging",
                    "description": "Four-hectare urban park pathways and mini-forest jogging loop.",
                    "availability": "always",
                    "fee_included_in_admission": True,
                    "effort_level": "easy",
                    "source_url": (
                        "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/"
                    ),
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Durian Dome & Sculptures Viewing",
                    "description": "Sightseeing at the giant Durian Dome, dancing fountain, and Kublai Millan sculptures.",
                    "availability": "always",
                    "fee_included_in_admission": True,
                    "effort_level": "easy",
                    "source_url": (
                        "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/"
                    ),
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Sunken Garden & Children's Playground",
                    "description": "Family play area, learning center, and landscaped Sunken Garden.",
                    "availability": "always",
                    "fee_included_in_admission": True,
                    "effort_level": "easy",
                    "source_url": (
                        "https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/"
                    ),
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("arrival_lat", "arrival_lng", "route_ready", "parking_note"),
        notes="Official Davao City Tourism page confirms daily 1:00 PM-10:00 PM hours and free admission.",
    ),
    DestinationEnrichmentPlan(
        destination_id=2,
        name="Philippine Eagle Center",
        source_urls=(
            "https://www.philippineeaglefoundation.org/pec",
            "https://www.philippineeaglefoundation.org/book-online",
            "https://www.philippineeaglefoundation.org/service-page/into-the-wild-tour",
        ),
        source_type="operator_site",
        patch_fields={
            "operating_status": "open",
            "booking_requirement": "recommended",
            "booking_note": "Online tour booking available at philippineeaglefoundation.org/book-online.",
        },
        activities_payload={
            "activities": [
                {
                    "name": "Into the Wild Tour",
                    "description": "Guided Philippine Eagle Center conservation tour (starts from PHP 120; confirm package online).",
                    "availability": "scheduled",
                    "duration_min_minutes": 45,
                    "duration_max_minutes": 45,
                    "effort_level": "easy",
                    "source_url": "https://www.philippineeaglefoundation.org/service-page/into-the-wild-tour",
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("hours_payload", "prices_payload", "arrival_lat", "arrival_lng"),
        notes="PEF booking page lists 'From PHP 120' (not fixed gate price) and omits static clock hours; structured /hours and /prices kept omitted.",
    ),
    DestinationEnrichmentPlan(
        destination_id=3,
        name="Eden Nature Park",
        source_urls=(
            "https://www.edennaturepark.com.ph/rates/",
            "https://www.edennaturepark.com.ph/recreational-activities/",
        ),
        source_type="operator_site",
        patch_fields={
            "operating_hours": "Mondays - Sundays, 9:00 AM - 5:00 PM",
            "operating_status": "open",
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.edennaturepark.com.ph/rates/",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("09:00:00", "17:00:00"),
            "exceptions": [],
        },
        activities_payload={
            "activities": [
                {
                    "name": "Guided Shuttle Tour",
                    "description": "Guided shuttle sightseeing around Eden's mountain gardens, amphitheater, and viewpoints.",
                    "availability": "scheduled",
                    "effort_level": "easy",
                    "source_url": "https://www.edennaturepark.com.ph/recreational-activities/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Skyrider",
                    "description": "Mountain zipline attraction at Eden Nature Park.",
                    "effort_level": "moderate",
                    "weather_dependency": "dry_weather",
                    "source_url": "https://www.edennaturepark.com.ph/recreational-activities/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Skycycle",
                    "description": "Elevated cable cycling attraction overlooking the mountain resort.",
                    "effort_level": "moderate",
                    "weather_dependency": "dry_weather",
                    "source_url": "https://www.edennaturepark.com.ph/recreational-activities/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Skyswing",
                    "description": "High-altitude giant swing attraction at Eden Nature Park.",
                    "effort_level": "challenging",
                    "weather_dependency": "dry_weather",
                    "source_url": "https://www.edennaturepark.com.ph/recreational-activities/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Horseback Riding",
                    "description": "Guided horseback trail ride inside Eden Nature Park.",
                    "effort_level": "easy",
                    "source_url": "https://www.edennaturepark.com.ph/recreational-activities/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Fishing Village",
                    "description": "Catch-and-cook or take-home recreational fishing pond.",
                    "effort_level": "easy",
                    "source_url": "https://www.edennaturepark.com.ph/rates/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Hiking Trail",
                    "description": "Ravine walks and boulder paths through Eden's pine forest.",
                    "effort_level": "moderate",
                    "weather_dependency": "dry_weather",
                    "source_url": "https://www.edennaturepark.com.ph/rates/",
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("prices_payload", "extra_fee"),
        notes="Official rates page confirms Resort Hours 9:00 AM-5:00 PM daily; itemized package/ride peso rates not printed in static HTML so /prices omitted.",
    ),
    DestinationEnrichmentPlan(
        destination_id=7,
        name="Panabo City Parks and Plaza",
        source_urls=("https://www.openstreetmap.org/way/614154998",),
        source_type="osm",
        patch_fields={
            "category": "public plaza",
            "budget_class": "budget",
        },
        fields_kept_null=("hours_payload", "prices_payload"),
        notes="Fix corrupted budget_class='true' -> 'budget' and normalize category to match preference_groups.",
    ),
    DestinationEnrichmentPlan(
        destination_id=14,
        name="Museo Dabawenyo",
        source_urls=(
            "https://davaocity.gov.ph/wp-content/uploads/2026/03/CGD_CC2026_VOLUMEIIE.pdf",
        ),
        source_type="official_lgu",
        prices_payload={
            "fees_source_url": (
                "https://davaocity.gov.ph/wp-content/uploads/2026/03/CGD_CC2026_VOLUMEIIE.pdf"
            ),
            "fees_verified_at": VERIFIED_AT,
            "prices": [
                {
                    "item": "entrance",
                    "audience": "everyone",
                    "amount": Decimal("0.00"),
                    "unit": "per_person",
                    "note": "No entrance fee listed for public museum tours in the 2026 Davao City Citizen's Charter.",
                },
            ],
        },
        fields_kept_null=("hours_payload", "arrival_lat", "arrival_lng"),
        notes="2026 Davao City Citizen's Charter confirms free museum tours; clock hours kept omitted pending direct schedule check.",
    ),
    DestinationEnrichmentPlan(
        destination_id=15,
        name="National Museum of the Philippines - Davao",
        source_urls=("https://www.nationalmuseum.gov.ph/nmp-davao/",),
        source_type="official_lgu",
        patch_fields={
            "description": (
                "Six-story durian-inspired regional component museum of the National Museum of the "
                "Philippines in People's Park Compound, Davao City showcasing Mindanao natural history, "
                "cultural heritage, Indigenous textiles, and works by Davao local and national artists."
            ),
            "operating_status": "open",
        },
        activities_payload={
            "activities": [
                {
                    "name": "Mindanao Natural History & Cultural Exhibits",
                    "description": "Four floors of natural history, ethnographic artifacts, and Mindanao heritage galleries.",
                    "effort_level": "easy",
                    "source_url": "https://www.nationalmuseum.gov.ph/nmp-davao/",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Indigenous Textiles & Davao Art Galleries",
                    "description": "Exhibitions highlighting Indigenous textiles and works by local and national artists.",
                    "effort_level": "easy",
                    "source_url": "https://www.nationalmuseum.gov.ph/nmp-davao/",
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("hours_payload", "prices_payload", "arrival_lat", "arrival_lng"),
        notes="Official NMP Davao page verified (HTTP 200); exact opening hours/fee rules not printed on page HTML so /hours and /prices omitted.",
    ),
    DestinationEnrichmentPlan(
        destination_id=16,
        name="Aqua Water Park",
        source_urls=(
            "https://onlineshopping.aquaria.landcolifestyleventures.com/?ID=413&page=product&val1=aqua-water-park-samal-islanddavao-2026-day-tour-pass-for-adults-weekdays",
            "https://www.landcolifestyleventures.com/day-tour/aqua-water-park/",
        ),
        source_type="operator_site",
        prices_payload={
            "fees_source_url": (
                "https://onlineshopping.aquaria.landcolifestyleventures.com/?ID=413&page=product&val1=aqua-water-park-samal-islanddavao-2026-day-tour-pass-for-adults-weekdays"
            ),
            "fees_verified_at": VERIFIED_AT,
            "prices": [
                {
                    "item": "entrance",
                    "audience": "adult",
                    "amount": Decimal("570.00"),
                    "unit": "per_person",
                    "note": "2026 online weekday adult day-tour pass (other days and rates vary).",
                },
            ],
        },
        fields_kept_null=("hours_payload", "arrival_lat", "arrival_lng"),
        notes="Operator page displays conflicting hours ('Open Daily 8:00 am to 6:00 pm' and 'Close every Tuesdays'); structured /hours intentionally skipped.",
    ),
    DestinationEnrichmentPlan(
        destination_id=19,
        name="Panabo Mangrove Forest Park",
        source_urls=(
            "https://www.openstreetmap.org/way/1436929311",
            "https://panabocity.gov.ph/",
        ),
        source_type="osm",
        patch_fields={
            "operating_hours": "Mo-Su 08:00-17:00",
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.openstreetmap.org/way/1436929311",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("08:00:00", "17:00:00"),
            "exceptions": [],
        },
        fields_kept_null=("prices_payload", "estimated_cost", "budget_class"),
        notes="OSM triage way/1436929311 confirms Mo-Su 08:00-17:00; visitor fees remain unconfirmed.",
    ),
    DestinationEnrichmentPlan(
        destination_id=22,
        name="San Salvador del Mundo Church",
        source_urls=("https://davaooriental.gov.ph/wp-content/uploads/2022/01/0.0-Citizens-Charter-v1.3.pdf",),
        source_type="official_lgu",
        patch_fields={"name": "San Salvador del Mundo Church"},
        fields_kept_null=("hours_payload", "prices_payload"),
        notes="Fix spelling typo in live catalog ('Churcg' -> 'Church'), matching places.csv.",
    ),

    # --- Priority 1: Core places.csv Gaps (IDs 31..41) ----------------------
    DestinationEnrichmentPlan(
        destination_id=31,
        name="Malagos Garden Resort",
        source_urls=(
            "https://www.malagos.com/our-story",
            "https://www.malagos.com/explore",
            "https://www.malagos.com/dine",
            "https://www.openstreetmap.org/way/976238615",
        ),
        source_type="operator_site",
        patch_fields={
            "description": (
                "Agri-ecotourism resort in Malagos, Baguio District, Davao City (established 1994) "
                "featuring the Malagos Chocolate Museum, Museo de Mariposa butterfly sanctuary, "
                "bird-feeding dome, interactive bird show, petting zoo, and farm-to-table dining."
            ),
            "activities": (
                "interactive bird show, falconry show, chocolate making, pizza making, "
                "bird feeding, butterfly encounter, animal feeding, koi feeding, paper mache painting"
            ),
            "operating_status": "open",
            "booking_requirement": "recommended",
            "best_time_to_visit": "Morning to afternoon",
            "best_time_basis": "Malagos Garden Resort experiences and Koi Cafe operating schedule (malagos.com).",
            "how_to_get_there": (
                "Located in Malagos, Baguio District, Davao City via Calinan; "
                "confirm day-tour availability and reservations with the resort."
            ),
        },
        activities_payload={
            "activities": [
                {
                    "name": "Malagos Interactive Birdshow",
                    "description": "Educational interactive wildlife and bird presentation.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Falconry Show",
                    "description": "Guided raptor flight and falconry demonstration.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Chocolate Making",
                    "description": "Hands-on bean-to-bar cacao and chocolate crafting experience.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Pizza Making",
                    "description": "Guided culinary pizza-making activity.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Bird Feeding",
                    "description": "Walk-in hand-feeding experience inside the Bird Feeding Dome.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Butterfly Encounter",
                    "description": "Walkthrough garden experience at the Malagos Butterfly Sanctuary.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Animal Feeding",
                    "description": "Supervised feeding of ducks, horses, and goats at the petting zoo.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Koi Feeding",
                    "description": "Self-paced koi pond feeding activity.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Paper Mache Painting",
                    "description": "Hands-on arts and crafts painting session.",
                    "effort_level": "easy",
                    "source_url": "https://www.malagos.com/explore",
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("entrance_fee", "estimated_cost", "budget_class", "hours_payload", "prices_payload"),
        notes="Activities verified directly from malagos.com/explore; day-tour admission peso rate not printed in static HTML so entrance_fee/prices kept omitted.",
    ),
    DestinationEnrichmentPlan(
        destination_id=32,
        name="Casas Con Vistas Resort",
        source_urls=(
            "https://www.casasconvistas.ph/",
            "https://www.casasconvistas.ph/day-tour",
            "https://www.casasconvistas.ph/about-us",
        ),
        source_type="operator_site",
        patch_fields={
            "location": "Purok 4, Barangay Pangubatan, Kaputian District, Island Garden City of Samal, Davao del Norte",
            "description": (
                "Coastal resort in Barangay Pangubatan, Kaputian District on Samal Island featuring "
                "white coral shores, day-tour beach and infinity pool passes, open cabanas, "
                "water sports, and island villas."
            ),
            "activities": "beach swimming, infinity pool swimming, water sports, day tour, villa stay",
            "estimated_cost": Decimal("1050.00"),
            "budget_class": "mid_range",
            "operating_status": "open",
            "booking_requirement": "recommended",
            "best_time_to_visit": "10:00 AM to 6:00 PM (day-tour schedule)",
            "best_time_basis": "Official day-tour hours on casasconvistas.ph/day-tour.",
            "how_to_get_there": (
                "Located at Purok 4, Barangay Pangubatan, Kaputian District on Samal Island; "
                "arrange ferry/boat transfer from Davao City and confirm arrival instructions with the resort."
            ),
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.casasconvistas.ph/day-tour",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("10:00:00", "18:00:00"),
            "exceptions": [],
        },
        prices_payload={
            "fees_source_url": "https://www.casasconvistas.ph/day-tour",
            "fees_verified_at": VERIFIED_AT,
            "prices": [
                {
                    "item": "other",
                    "audience": "adult",
                    "amount": Decimal("50.00"),
                    "unit": "per_person",
                    "age_min": 10,
                    "note": "On-site environmental fee for guests 10 years old and above.",
                },
                {
                    "item": "other",
                    "audience": "senior",
                    "amount": Decimal("40.00"),
                    "unit": "per_person",
                    "note": "On-site environmental fee for Senior Citizens and PWDs.",
                },
                {
                    "item": "entrance",
                    "audience": "everyone",
                    "amount": Decimal("1000.00"),
                    "unit": "per_person",
                    "note": "Weekday beach-access day tour (weekend PHP 1,500); includes PHP 500 food & drinks credit.",
                },
                {
                    "item": "other",
                    "audience": "everyone",
                    "amount": Decimal("1500.00"),
                    "unit": "per_person",
                    "note": "Weekday beach + infinity pool day tour (weekend PHP 2,000); includes PHP 500 food & drinks credit.",
                },
            ],
        },
        activities_payload={
            "activities": [
                {
                    "name": "Beach Access Day Tour",
                    "description": "Day access to white coral beach, open cabana/umbrella cottage, towel use, and PHP 500 F&B credit.",
                    "availability": "scheduled",
                    "schedule_note": "10:00 AM to 6:00 PM",
                    "effort_level": "easy",
                    "weather_dependency": "daylight",
                    "source_url": "https://www.casasconvistas.ph/day-tour",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Infinity Pool Day Tour",
                    "description": "Beach access plus infinity pool pass during day-tour hours.",
                    "availability": "scheduled",
                    "schedule_note": "10:00 AM to 6:00 PM",
                    "effort_level": "easy",
                    "source_url": "https://www.casasconvistas.ph/day-tour",
                    "verified_at": VERIFIED_AT,
                },
                {
                    "name": "Water Sport Session",
                    "description": "Free 30-minute use of 1 water sport per group included with day-tour passes.",
                    "availability": "scheduled",
                    "duration_min_minutes": 30,
                    "duration_max_minutes": 30,
                    "fee_included_in_admission": True,
                    "effort_level": "moderate",
                    "weather_dependency": "calm_seas",
                    "source_url": "https://www.casasconvistas.ph/day-tour",
                    "verified_at": VERIFIED_AT,
                },
            ],
        },
        fields_kept_null=("arrival_lat", "arrival_lng", "route_ready"),
        notes="Official operator day-tour page confirms 10:00 AM-6:00 PM hours, itemized weekday/weekend & environmental fees, and activities.",
    ),
    DestinationEnrichmentPlan(
        destination_id=33,
        name="D' Bone Collector Museum",
        source_urls=("https://www.openstreetmap.org/way/201735372",),
        source_type="osm",
        patch_fields={
            "description": (
                "Three-story natural history and osteology museum in Barangay 76-A, Bucana, Davao City "
                "exhibiting skeletal specimens of marine and terrestrial wildlife from the Philippines "
                "and around the world."
            ),
            "entrance_fee": "Paid admission (confirm current ticket rate with museum before visiting)",
            "activities": "museum visit, skeletal specimen viewing, guided educational tour",
            "operating_status": "open",
            "best_time_to_visit": "Monday to Saturday, 10:00 AM to 4:00 PM",
            "best_time_basis": "OSM opening_hours tag (Mo-Sa 10:00-16:00, Su off) on way/201735372.",
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.openstreetmap.org/way/201735372",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("10:00:00", "16:00:00", closed_weekdays=frozenset({6})),
            "exceptions": [],
        },
        fields_kept_null=("prices_payload", "estimated_cost", "budget_class"),
        notes="OSM way/201735372 verifies Mo-Sa 10:00-16:00 (Sun closed) and fee=yes; exact peso fee omitted pending direct operator confirmation.",
    ),
    DestinationEnrichmentPlan(
        destination_id=34,
        name="Monfort Bat Sanctuary",
        source_urls=(
            "https://www.openstreetmap.org/way/666853611",
            "https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits",
        ),
        source_type="official_lgu",
        patch_fields={
            "location": "Barangay Tambo, Babak District, Island Garden City of Samal, Davao del Norte",
            "description": (
                "Wildlife conservation sanctuary in Barangay Tambo, Babak District on Samal Island "
                "protecting a large colony of Geoffroy's rousette fruit bats in natural caves."
            ),
            "activities": "bat cave viewing, conservation talk, nature walk",
            "how_to_get_there": (
                "Located in Barangay Tambo, Babak District on Samal Island; accessible by road "
                "after crossing via the Sasa-Babak ferry from Davao City."
            ),
        },
        fields_kept_null=("operating_hours", "hours_payload", "prices_payload", "estimated_cost"),
        notes="Location and conservation purpose grounded in PIA DavNor circuit report & OSM way/666853611; hours kept null until direct operator check.",
    ),
    DestinationEnrichmentPlan(
        destination_id=35,
        name="Bukid Amara",
        source_urls=("https://www.openstreetmap.org/way/1470781676",),
        source_type="osm",
        patch_fields={
            "description": (
                "Flower farm and hillside garden attraction in Barangay Bago Gallera, Davao City "
                "featuring seasonal flower beds and scenic photo spots."
            ),
            "best_time_to_visit": "Morning or late afternoon (8:00 AM to 5:30 PM daily)",
            "best_time_basis": "OSM opening_hours tag (Mo-Su 08:00-17:30) on way/1470781676.",
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.openstreetmap.org/way/1470781676",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("08:00:00", "17:30:00"),
            "exceptions": [],
        },
        fields_kept_null=("entrance_fee", "estimated_cost", "budget_class", "prices_payload"),
        notes="Hours grounded in OSM way/1470781676; bukidamara.com belongs to Lucban, Quezon and was intentionally excluded.",
    ),
    DestinationEnrichmentPlan(
        destination_id=36,
        name="Calamba Farm Sea of Clouds",
        source_urls=(
            "https://calambafarm.com/",
            "https://www.openstreetmap.org/node/7159866285",
        ),
        source_type="operator_site",
        patch_fields={
            "location": "Maragusan, Davao de Oro",
            "description": (
                "Mountain resort and highland viewpoint in Maragusan, Davao de Oro known for "
                "sunrise vistas and sea-of-clouds formations over the valley."
            ),
            "best_time_to_visit": "Early morning (around sunrise for sea of clouds)",
            "best_time_basis": "Official site positioning on calambafarm.com.",
        },
        hours_payload={
            "open_24_hours": True,
            "hours_source_url": "https://www.openstreetmap.org/node/7159866285",
            "hours_verified_at": VERIFIED_AT,
            "weekly": [],
            "exceptions": [],
        },
        fields_kept_null=("entrance_fee", "estimated_cost", "budget_class", "prices_payload"),
        notes="OSM node/7159866285 verifies 24/7 access; calambafarm.com verifies Maragusan sunrise viewpoint; fees omitted pending operator table.",
    ),
    DestinationEnrichmentPlan(
        destination_id=37,
        name="Mount Hamiguitan Range Wildlife Sanctuary",
        source_urls=(
            "https://www.openstreetmap.org/way/1120154773",
            "https://ppp.gov.ph/in_the_news/boosting-world-class-hospitality-in-davors-tourism-sites/",
            "https://denr.gov.ph/wp-content/uploads/2023/07/DENR_News_Alerts_April_13_2022_Wednesday.pdf",
        ),
        source_type="official_lgu",
        patch_fields={
            "location": "San Isidro / Governor Generoso, Davao Oriental",
            "description": (
                "UNESCO World Heritage protected mountain sanctuary in Davao Oriental famous for its "
                "mossy pygmy forest and endemic wildlife; trekking requires advance DENR protected-area "
                "permits and guided registration."
            ),
            "entrance_fee": "Permit and guide fees required for trekking; confirm current eco-park and DENR rates",
            "activities": "nature walk, pygmy forest viewing, guided heritage trek",
            "booking_requirement": "required",
            "booking_note": (
                "Advance permit, booking, and trailhead registration with the DENR protected-area "
                "office are required for mountain trekking."
            ),
        },
        fields_kept_null=("operating_hours", "hours_payload", "prices_payload", "estimated_cost"),
        notes="Permit/booking requirement grounded in DENR report & candidate README; hours and exact trek fees left null pending PAMB confirmation.",
    ),
    DestinationEnrichmentPlan(
        destination_id=39,
        name="Dahican Surf Resort",
        source_urls=(
            "https://www.openstreetmap.org/node/6427841589",
            "https://ppp.gov.ph/in_the_news/boosting-world-class-hospitality-in-davors-tourism-sites/",
        ),
        source_type="osm",
        patch_fields={
            "description": (
                "Beachfront surf and skimboarding resort along Dahican Beach in Mati City, "
                "Davao Oriental offering oceanfront access and board-riding spots."
            ),
            "entrance_fee": "Paid day-use or resort fee applies; confirm current rate with resort",
            "activities": "swimming, surfing, skimboarding, beach lounging",
            "best_time_to_visit": "Morning to late afternoon",
            "best_time_basis": "OSM node/6427841589 and Dahican coastal access.",
        },
        hours_payload={
            "open_24_hours": True,
            "hours_source_url": "https://www.openstreetmap.org/node/6427841589",
            "hours_verified_at": VERIFIED_AT,
            "weekly": [],
            "exceptions": [],
        },
        fields_kept_null=("prices_payload", "estimated_cost", "budget_class"),
        notes="OSM node/6427841589 verifies 24/7 and fee=yes; exact current resort peso rates omitted.",
    ),
    DestinationEnrichmentPlan(
        destination_id=40,
        name="Isla Reta Beach Resort",
        source_urls=(
            "https://www.openstreetmap.org/relation/14964367",
            "https://vatphil.com/viewchart.php?id=484",
        ),
        source_type="osm",
        patch_fields={
            "location": "Barangay Santa Cruz, Talikud Island, Island Garden City of Samal, Davao del Norte",
            "description": (
                "White-sand beachfront resort in Barangay Santa Cruz on Talikud Island (Samal Group), "
                "popular for clear-water swimming, snorkeling, and overnight beach stays."
            ),
            "activities": "swimming, snorkeling, beach camping, island relaxation",
            "how_to_get_there": (
                "Accessible by public or chartered boat from Sta. Ana Wharf in Davao City "
                "(or Kaputian on Samal Island) to Talikud Island; confirm departure schedules before travel."
            ),
        },
        hours_payload={
            "open_24_hours": True,
            "hours_source_url": "https://www.openstreetmap.org/relation/14964367",
            "hours_verified_at": VERIFIED_AT,
            "weekly": [],
            "exceptions": [],
        },
        fields_kept_null=("entrance_fee", "estimated_cost", "budget_class", "prices_payload"),
        notes="OSM relation/14964367 verifies 24/7 access; entrance fee omitted pending direct operator confirmation.",
    ),
    DestinationEnrichmentPlan(
        destination_id=41,
        name="Uraya's Peak Adventure Park",
        source_urls=("https://www.openstreetmap.org/way/1161948892",),
        source_type="osm",
        patch_fields={
            "location": "Barangay Santo Niño, Talaingod, Davao del Norte",
            "description": (
                "Highland viewpoint and adventure park in Barangay Santo Niño, Talaingod, "
                "Davao del Norte offering mountain ridge vistas, scenic decks, and day-tour leisure."
            ),
            "activities": "sightseeing, mountain viewing, photography, day tour",
            "estimated_cost": Decimal("160.00"),
            "budget_class": "budget",
            "best_time_to_visit": "Early morning (6:00 AM to 9:00 AM)",
            "best_time_basis": "OSM opening_hours tag (Mo-Su 06:00-17:00) on way/1161948892.",
        },
        hours_payload={
            "open_24_hours": False,
            "hours_source_url": "https://www.openstreetmap.org/way/1161948892",
            "hours_verified_at": VERIFIED_AT,
            "weekly": _daily_weekly("06:00:00", "17:00:00"),
            "exceptions": [],
        },
        fields_kept_null=("prices_payload", "arrival_lat", "arrival_lng"),
        notes="OSM way/1161948892 confirms Mo-Su 06:00-17:00; estimated_cost aligns with existing catalog PHP 160 day-tour text.",
    ),

    # --- Priority 2: Davao del Norte / Samal records (IDs 42..46, 48..63) ----
    DestinationEnrichmentPlan(
        destination_id=42,
        name="Agriya Naturetainment",
        source_urls=(
            "https://damosaland.com/agriya/",
            "https://www.openstreetmap.org/node/14282996052",
        ),
        source_type="operator_site",
        patch_fields={
            "district": "Davao del Norte",
            "category": "nature park",
            "activities": "interactive farming, linear park walk, family recreation, dining at Agriya Strip",
            "operating_status": "open",
        },
        fields_kept_null=("image_url", "entrance_fee", "estimated_cost", "budget_class"),
        notes="Activities grounded in damosaland.com/agriya/; fees and CC/PD venue photo unverified so kept null.",
    ),
    DestinationEnrichmentPlan(
        destination_id=43,
        name="Panabo City Seawall and Park",
        source_urls=("https://www.openstreetmap.org/way/1304265317",),
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "park",
            "budget_class": "budget",
            "how_to_get_there": (
                "Located along Panabo City Coastal Road; reachable by tricycle or private vehicle "
                "from downtown Panabo City."
            ),
        },
        fields_kept_null=("image_url", "hours_payload"),
        notes="Normalize district and category; leave hours_payload omitted per candidate CSV 24h confirmation hold and image_url null.",
    ),
    DestinationEnrichmentPlan(
        destination_id=44,
        name="Museo Panabo",
        source_urls=(
            "https://panabocity.gov.ph/",
            "https://www.openstreetmap.org/way/304043759",
        ),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "location": "Panabo City Hall / Central Park Compound, Panabo City, Davao del Norte",
            "category": "museum",
            "activities": "museum visit, local heritage exhibits, cultural appreciation",
            "budget_class": "budget",
            "how_to_get_there": (
                "Located in central Panabo City near the City Park; accessible by tricycle from "
                "Panabo City proper."
            ),
        },
        fields_kept_null=("image_url", "hours_payload", "prices_payload"),
        notes="Normalize district, category, and corrupted budget_class='0' -> 'budget'; venue photo unverified.",
    ),
    DestinationEnrichmentPlan(
        destination_id=45,
        name="Maria Clara Resort",
        source_urls=("https://www.openstreetmap.org/node/1",),  # replaced below with Waze/OSM? Let's use supported CSV Waze/Osm? Wait:
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url", "hours_payload", "prices_payload"),
        notes="Normalize district, category, and set budget_class='budget' matching existing estimated_cost=300.",
    ),
    DestinationEnrichmentPlan(
        destination_id=46,
        name="Sky Deck Garden Cafe and Restaurant",
        source_urls=("https://panabocity.gov.ph/",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "cafe / restaurant",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district and fix corrupted budget_class='0' -> 'budget'.",
    ),
    DestinationEnrichmentPlan(
        destination_id=48,
        name="Tagum Freedom Park",
        source_urls=("https://sp.tagumcity.gov.ph/wp-content/uploads/2022/10/CO-848-18.pdf",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "public plaza",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district, category, and fix corrupted budget_class='0' -> 'budget'; no verified CC/PD Freedom Park photo found.",
    ),
    DestinationEnrichmentPlan(
        destination_id=49,
        name="Energy Park",
        source_urls=("https://issuances-library.senate.gov.ph/executive-issuance/proclamation-no-1748-s-2009",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "nature park",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district, category, and fix corrupted budget_class='0' -> 'budget'.",
    ),
    DestinationEnrichmentPlan(
        destination_id=50,
        name="San Agustin Botanical Park",
        source_urls=("https://www.openstreetmap.org/relation/19697552",),
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "garden",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district, category, and fix corrupted budget_class='0' -> 'budget'.",
    ),
    DestinationEnrichmentPlan(
        destination_id=51,
        name="Tagum New City Hall",
        source_urls=("https://commons.wikimedia.org/wiki/File:Newtagumcityhall.jpg",),
        source_type="wikimedia_commons",
        patch_fields={
            "district": "Davao del Norte",
            "category": "landmark",
            "budget_class": "budget",
        },
        image_spec=ImageSpec(
            file_title="File:Newtagumcityhall.jpg",
            commons_page_url="https://commons.wikimedia.org/wiki/File:Newtagumcityhall.jpg",
            direct_url="https://upload.wikimedia.org/wikipedia/commons/2/26/Newtagumcityhall.jpg",
            mime_type="image/jpeg",
            license_name="CC BY-SA 3.0",
            author="S5switch",
            size_bytes=174472,
        ),
        notes="Verified Wikimedia Commons photo File:Newtagumcityhall.jpg (CC BY-SA 3.0) + district/budget_class normalization.",
    ),
    DestinationEnrichmentPlan(
        destination_id=52,
        name="World's largest Rosary",
        source_urls=(
            "https://commons.wikimedia.org/wiki/File:Christ_The_King_Cathedral_Tagum.jpg",
            "https://www.openstreetmap.org/way/753476253",
        ),
        source_type="wikimedia_commons",
        patch_fields={
            "district": "Davao del Norte",
            "category": "religious landmark",
            "budget_class": "budget",
        },
        image_spec=ImageSpec(
            file_title="File:Christ_The_King_Cathedral_Tagum.jpg",
            commons_page_url="https://commons.wikimedia.org/wiki/File:Christ_The_King_Cathedral_Tagum.jpg",
            direct_url="https://upload.wikimedia.org/wikipedia/commons/5/5f/Christ_The_King_Cathedral_Tagum.jpg",
            mime_type="image/jpeg",
            license_name="CC BY 3.0",
            author="S5switch",
            size_bytes=1278474,
        ),
        notes="Holy Rosary Garden is inside Christ the King Cathedral Compound; verified Wikimedia Commons photo (CC BY 3.0) + normalization.",
    ),
    DestinationEnrichmentPlan(
        destination_id=53,
        name="Huyong-huyong Nature Park",
        source_urls=("https://www.openstreetmap.org/way/926328738",),
        source_type="osm",
        patch_fields={
            "category": "nature park",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Fix corrupted budget_class='0' -> 'budget' and normalize category.",
    ),
    DestinationEnrichmentPlan(
        destination_id=54,
        name="Davao del Norte Sports and Tourism Complex (DNSTC)",
        source_urls=("https://commons.wikimedia.org/wiki/File:DNSTC_Aquatic_Center.jpg",),
        source_type="wikimedia_commons",
        patch_fields={
            "district": "Davao del Norte",
            "category": "sports complex",
            "budget_class": "budget",
        },
        image_spec=ImageSpec(
            file_title="File:DNSTC_Aquatic_Center.jpg",
            commons_page_url="https://commons.wikimedia.org/wiki/File:DNSTC_Aquatic_Center.jpg",
            direct_url="https://upload.wikimedia.org/wikipedia/commons/8/8a/DNSTC_Aquatic_Center.jpg",
            mime_type="image/jpeg",
            license_name="CC BY-SA 4.0",
            author="S5switch",
            size_bytes=1776723,
        ),
        fields_kept_null=("operating_hours", "hours_payload"),
        notes="Verified Wikimedia Commons photo File:DNSTC_Aquatic_Center.jpg (CC BY-SA 4.0) + normalization; hours kept null.",
    ),
    DestinationEnrichmentPlan(
        destination_id=55,
        name="Tagum City Historical & Cultural center",
        source_urls=("https://sp.tagumcity.gov.ph/wp-content/uploads/2022/10/CO-848-18.pdf",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "museum",
            "budget_class": "budget",
        },
        fields_kept_null=("image_url",),
        notes="Normalize verbose sentence category -> 'museum', district, and budget_class='budget'.",
    ),
    DestinationEnrichmentPlan(
        destination_id=56,
        name="Tagum City River Cruise / Nabintad River",
        source_urls=("https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "nature park",
            "budget_class": "mid_range",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district, category, and budget_class='mid_range' (estimated_cost=500).",
    ),
    DestinationEnrichmentPlan(
        destination_id=57,
        name="Banana Beach at Hijo Resorts Davao",
        source_urls=(
            "https://depeddavnor.ph/records/officememo/DM-OSDS-2025-0199%20-%20LAND%20TITLING%20ISSUES%20AND%20SOLUTIONS%20A%20MULTI-PERSPECTIVE%20APPROACH.pdf",
        ),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "mid_range",
        },
        fields_kept_null=("image_url",),
        notes="Normalize district, category, and budget_class='mid_range' (estimated_cost=1650).",
    ),
    DestinationEnrichmentPlan(
        destination_id=58,
        name="Lanikai Hijo Estate Resort",
        source_urls=("https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits",),
        source_type="official_lgu",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "premium",
        },
        fields_kept_null=("image_url", "operating_hours", "entrance_fee"),
        notes="Normalize district, category, and budget_class='premium' (estimated_cost=5000); unverified hours/day fee kept null.",
    ),
    DestinationEnrichmentPlan(
        destination_id=59,
        name="LYR Agro Inland Resort",
        source_urls=("https://www.openstreetmap.org/way/1431254432",),
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "resort",
            "budget_class": "mid_range",
        },
        fields_kept_null=("image_url",),
        notes="Normalize verbose sentence category -> 'resort', district, and budget_class='mid_range' (estimated_cost=600).",
    ),
    DestinationEnrichmentPlan(
        destination_id=60,
        name="Pearl Farm Beach Resort",
        source_urls=(
            "https://pearlfarmresort.com/",
            "https://pearlfarmresort.com/experience/",
            "https://commons.wikimedia.org/wiki/File:Pearl_Farm_Davao_Philippines.jpg",
        ),
        source_type="operator_site",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "premium",
            "operating_status": "open",
        },
        image_spec=ImageSpec(
            file_title="File:Pearl_Farm_Davao_Philippines.jpg",
            commons_page_url="https://commons.wikimedia.org/wiki/File:Pearl_Farm_Davao_Philippines.jpg",
            direct_url="https://upload.wikimedia.org/wikipedia/commons/b/bc/Pearl_Farm_Davao_Philippines.jpg",
            mime_type="image/jpeg",
            license_name="CC BY-SA 4.0",
            author="Jimboyperez",
            size_bytes=1741823,
        ),
        notes="Verified Wikimedia Commons photo File:Pearl_Farm_Davao_Philippines.jpg (CC BY-SA 4.0) + category/district/budget_class normalization.",
    ),
    DestinationEnrichmentPlan(
        destination_id=61,
        name="Paradise Island Park & Beach Resort",
        source_urls=("https://www.openstreetmap.org/relation/9472621",),
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "mid_range",
        },
        fields_kept_null=("image_url",),
        notes="Normalize verbose sentence category -> 'beach resort', district, and budget_class='mid_range' (estimated_cost=1500).",
    ),
    DestinationEnrichmentPlan(
        destination_id=62,
        name="Discovery Samal",
        source_urls=(
            "https://www.discoverysamal.com/",
            "https://www.discoverysamal.com/offers",
            "https://www.openstreetmap.org/way/1002108565",
        ),
        source_type="operator_site",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "premium",
            "operating_status": "open",
        },
        fields_kept_null=("image_url", "entrance_fee"),
        notes="Normalize verbose sentence category -> 'beach resort', district, and budget_class='premium'; entrance_fee kept null.",
    ),
    DestinationEnrichmentPlan(
        destination_id=63,
        name="Chema's by the Sea",
        source_urls=("https://www.openstreetmap.org/way/158515617",),
        source_type="osm",
        patch_fields={
            "district": "Davao del Norte",
            "category": "beach resort",
            "budget_class": "premium",
            "activities": None,
            "overnight_fee": None,
        },
        explicit_clear_fields=frozenset({"activities", "overnight_fee"}),
        fields_kept_null=("image_url", "entrance_fee", "activities", "overnight_fee"),
        notes=(
            "Normalize verbose sentence category -> 'beach resort', district, and budget_class='premium'; "
            "explicitly clear contaminated activities/overnight_fee copy-pasted from Discovery Samal."
        ),
    ),
)

# Fix ID 45 source URL cleanly (Waze/supported CSV link verified in davao_region_supported_place_candidates.csv line 73)
ENRICHMENT_PLANS = tuple(
    DestinationEnrichmentPlan(
        destination_id=p.destination_id,
        name=p.name,
        source_urls=(
            (
                "https://www.waze.com/live-map/directions/ph/davao-region/panabo/maria-clara-resort?to=place.ChIJq3rCZq5F-TIRYk5gNwuC0sQ",
            )
            if p.destination_id == 45
            else p.source_urls
        ),
        source_type=p.source_type,
        patch_fields=p.patch_fields,
        explicit_clear_fields=p.explicit_clear_fields,
        hours_payload=p.hours_payload,
        prices_payload=p.prices_payload,
        activities_payload=p.activities_payload,
        image_spec=p.image_spec,
        fields_kept_null=p.fields_kept_null,
        notes=p.notes,
    )
    for p in ENRICHMENT_PLANS
)


STAGED_CLIPS: tuple[StagedClipSpec, ...] = (
    StagedClipSpec(
        target_destination_id=6,
        target_name="Dahican Beach",
        media_type="gif",
        file_title="File:Breaking_waves_fast.gif",
        commons_page_url="https://commons.wikimedia.org/wiki/File:Breaking_waves_fast.gif",
        direct_url="https://upload.wikimedia.org/wikipedia/commons/9/94/Breaking_waves_fast.gif",
        mime_type="image/gif",
        license_name="CC BY-SA 3.0",
        author="Jahobr",
        raw_size_bytes=5643128,
        raw_duration_seconds=14.2,
        requires_trim_transcode=False,
        ffmpeg_command=None,
        notes="Generic looping ocean waves GIF (5.38 MB <= 10 MB, 14.2s <= 15s); ready as-is for M5A GIF upload test/staging.",
    ),
    StagedClipSpec(
        target_destination_id=61,
        target_name="Paradise Island Park & Beach Resort",
        media_type="video",
        file_title="File:Samal_Island_Views_-_September_2018.webm",
        commons_page_url="https://commons.wikimedia.org/wiki/File:Samal_Island_Views_-_September_2018.webm",
        direct_url="https://upload.wikimedia.org/wikipedia/commons/1/1c/Samal_Island_Views_-_September_2018.webm",
        mime_type="video/webm",
        license_name="CC BY-SA 4.0",
        author="RoyKabanlit",
        raw_size_bytes=27706071,
        raw_duration_seconds=84.818,
        requires_trim_transcode=True,
        ffmpeg_command=(
            "ffmpeg -ss 00:00:05 -t 12 -i Samal_Island_Views_-_September_2018.webm "
            "-an -c:v libvpx-vp9 -b:v 1.5M -vf \"scale='min(1280,iw)':-2\" "
            "samal_island_views_12s.webm"
        ),
        notes="Authentic Samal Island footage featuring Paradise Island Park & Beach Resort; requires trim to <=15s and <=15 MB under CC BY-SA 4.0.",
    ),
    StagedClipSpec(
        target_destination_id=1,
        target_name="People's Park",
        media_type="video",
        file_title="File:Greetings_from_WikiClub_Davao.webm",
        commons_page_url="https://commons.wikimedia.org/wiki/File:Greetings_from_WikiClub_Davao.webm",
        direct_url="https://upload.wikimedia.org/wikipedia/commons/a/a9/Greetings_from_WikiClub_Davao.webm",
        mime_type="video/webm",
        license_name="CC BY-SA 4.0",
        author="MadayawDavao",
        raw_size_bytes=3142989,
        raw_duration_seconds=9.5,
        requires_trim_transcode=False,
        ffmpeg_command=(
            "ffmpeg -i Greetings_from_WikiClub_Davao.webm -an -c:v copy "
            "greetings_davao_muted.webm"
        ),
        notes="Authentic Davao City WebM clip (3.00 MB <= 15 MB, 9.5s <= 15s); optional -an strip for muted auto-loop playback.",
    ),
    StagedClipSpec(
        target_destination_id=4,
        target_name="Samal Island Beach Area",
        media_type="video",
        file_title="File:Waves_at_Hikkaduwa_beach,_Sri_Lanka.webm",
        commons_page_url="https://commons.wikimedia.org/wiki/File:Waves_at_Hikkaduwa_beach,_Sri_Lanka.webm",
        direct_url="https://upload.wikimedia.org/wikipedia/commons/1/16/Waves_at_Hikkaduwa_beach%2C_Sri_Lanka.webm",
        mime_type="video/webm",
        license_name="CC BY-SA 4.0",
        author="Jan Kranendonk (https://www.jankranendonk.nl)",
        raw_size_bytes=1602290,
        raw_duration_seconds=7.018,
        requires_trim_transcode=False,
        ffmpeg_command=(
            "ffmpeg -i Waves_at_Hikkaduwa_beach,_Sri_Lanka.webm -an -c:v copy "
            "coastal_waves_muted.webm"
        ),
        notes="Generic coastal surf WebM sample (1.53 MB <= 15 MB, 7.02s <= 15s, filmed in Sri Lanka; labeled generic sample only).",
    ),
)


# ---------------------------------------------------------------------------
# Validation, diffing & HTTP execution helpers
# ---------------------------------------------------------------------------


def validate_plan_schemas(
    plans: tuple[DestinationEnrichmentPlan, ...] = ENRICHMENT_PLANS,
) -> dict[int, dict[str, Any]]:
    """Validate every curated payload against real Pydantic schemas and safety guards."""
    validated: dict[int, dict[str, Any]] = {}
    for plan in plans:
        forbidden_hit = ARRIVAL_GUARD_FIELDS.intersection(plan.patch_fields)
        if forbidden_hit:
            raise ValueError(
                f"Destination {plan.destination_id} ({plan.name}) attempted to mutate guarded "
                f"arrival/route_ready fields: {sorted(forbidden_hit)}"
            )
        entry: dict[str, Any] = {}
        if plan.patch_fields:
            patch_model = DestinationUpdate.model_validate(plan.patch_fields)
            entry["patch"] = patch_model.model_dump(mode="json", exclude_unset=True)
        if plan.hours_payload is not None:
            hours_model = DestinationHoursUpdate.model_validate(plan.hours_payload)
            entry["hours"] = hours_model.model_dump(mode="json")
        if plan.prices_payload is not None:
            prices_model = DestinationPricesUpdate.model_validate(plan.prices_payload)
            entry["prices"] = prices_model.model_dump(mode="json")
        if plan.activities_payload is not None:
            act_model = DestinationActivitiesUpdate.model_validate(plan.activities_payload)
            entry["activities"] = act_model.model_dump(mode="json")
        validated[plan.destination_id] = entry
    return validated


def _values_equal(live_val: Any, target_val: Any) -> bool:
    if live_val is None and target_val is None:
        return True
    if live_val is None or target_val is None:
        return False
    if isinstance(target_val, Decimal) or isinstance(live_val, Decimal):
        try:
            return Decimal(str(live_val)) == Decimal(str(target_val))
        except Exception:
            return False
    if isinstance(target_val, str) and isinstance(live_val, (int, float, Decimal)):
        try:
            return Decimal(str(live_val)) == Decimal(target_val)
        except Exception:
            pass
    return live_val == target_val


def compute_patch_diff(
    live_dest: dict[str, Any],
    plan: DestinationEnrichmentPlan,
) -> dict[str, Any]:
    """Compute minimal non-destructive PATCH payload (only fields that actually change)."""
    diff: dict[str, Any] = {}
    for key, target_val in plan.patch_fields.items():
        if key in ARRIVAL_GUARD_FIELDS:
            continue
        live_val = live_dest.get(key)
        if target_val is None:
            if key in plan.explicit_clear_fields and live_val is not None:
                diff[key] = None
            continue
        if not _values_equal(live_val, target_val):
            diff[key] = target_val
    if diff:
        DestinationUpdate.model_validate(diff)
    return diff


def should_apply_hours(
    existing: dict[str, Any] | None,
    *,
    overwrite: bool = False,
) -> bool:
    if overwrite or existing is None:
        return True
    has_structured = bool(existing.get("weekly")) or bool(existing.get("open_24_hours"))
    return not has_structured


def should_apply_prices(
    existing: dict[str, Any] | None,
    *,
    overwrite: bool = False,
) -> bool:
    if overwrite or existing is None:
        return True
    return not bool(existing.get("prices"))


def should_apply_activities(
    existing: dict[str, Any] | None,
    *,
    overwrite: bool = False,
) -> bool:
    if overwrite or existing is None:
        return True
    return not bool(existing.get("activities"))


def project_data_quality(
    plan: DestinationEnrichmentPlan,
    live_dest: dict[str, Any] | None = None,
    *,
    now: datetime | None = None,
) -> dict[str, str]:
    """Compute expected data_quality levels after enrichment using data_quality.py."""
    current = now or datetime.now(timezone.utc)
    has_text_hours = bool(
        (plan.patch_fields.get("operating_hours"))
        or (live_dest or {}).get("operating_hours")
    )
    has_struct_hours = plan.hours_payload is not None and (
        bool(plan.hours_payload.get("weekly")) or bool(plan.hours_payload.get("open_24_hours"))
    )
    hours_verified = plan.hours_payload.get("hours_verified_at") if plan.hours_payload else None

    has_text_fees = bool(
        plan.patch_fields.get("entrance_fee")
        or ((live_dest or {}).get("entrance_fee") if "entrance_fee" not in plan.explicit_clear_fields else None)
        or ((live_dest or {}).get("overnight_fee") if "overnight_fee" not in plan.explicit_clear_fields else None)
    )
    has_struct_prices = bool(plan.prices_payload and plan.prices_payload.get("prices"))
    fees_verified = plan.prices_payload.get("fees_verified_at") if plan.prices_payload else None

    has_struct_act = bool(plan.activities_payload and plan.activities_payload.get("activities"))
    act_verified = (
        plan.activities_payload["activities"][0].get("verified_at")
        if has_struct_act
        else None
    )
    return {
        "hours": data_quality(has_struct_hours, has_text_hours, hours_verified, now=current),
        "prices": data_quality(has_struct_prices, has_text_fees, fees_verified, now=current),
        "activities": data_quality(has_struct_act, False, act_verified, now=current)
        if has_struct_act
        else "unknown",
    }


def offline_fixture_catalog(
    plans: tuple[DestinationEnrichmentPlan, ...] = ENRICHMENT_PLANS,
) -> dict[int, dict[str, Any]]:
    """Minimal offline fixture representing un-enriched baseline destinations."""
    return {
        plan.destination_id: {
            "destination_id": plan.destination_id,
            "name": plan.name,
            "district": "Davao Del Norte" if plan.destination_id >= 42 else "Davao City",
            "category": None,
            "description": None,
            "operating_hours": None,
            "entrance_fee": None,
            "overnight_fee": "18,000" if plan.destination_id == 63 else None,
            "activities": "Discovery Samal copy" if plan.destination_id == 63 else None,
            "estimated_cost": None,
            "budget_class": "0" if plan.destination_id >= 44 else None,
            "image_url": "https://res.cloudinary.com/demo/image/upload/v1/old.jpg"
            if plan.destination_id < 42
            else None,
            "route_ready": plan.destination_id in {3, 31, 34},
            "arrival_lat": 7.1818 if plan.destination_id == 31 else None,
            "arrival_lng": 125.4192 if plan.destination_id == 31 else None,
        }
        for plan in plans
    }


def fetch_catalog(client: httpx.Client) -> dict[int, dict[str, Any]]:
    """Fetch all active destinations via paginated GET /destinations."""
    catalog: dict[int, dict[str, Any]] = {}
    offset = 0
    while True:
        resp = client.get("/destinations", params={"limit": 100, "offset": offset})
        resp.raise_for_status()
        page = resp.json()
        for row in page:
            catalog[int(row["destination_id"])] = row
        if len(page) < 100:
            break
        offset += len(page)
    return catalog


def env_readiness_booleans() -> dict[str, bool]:
    """Return boolean key presence only (never credential values)."""
    return {
        "LAKBAY_API_BASE_URL": bool(os.environ.get("LAKBAY_API_BASE_URL")),
        "LAKBAY_ADMIN_EMAIL": bool(os.environ.get("LAKBAY_ADMIN_EMAIL")),
        "LAKBAY_ADMIN_PASSWORD": bool(os.environ.get("LAKBAY_ADMIN_PASSWORD")),
    }


def login_admin(client: httpx.Client, *, email: str, password: str) -> str:
    """Authenticate via POST /auth/login and return Bearer access token."""
    resp = client.post("/auth/login", json={"email": email, "password": password})
    resp.raise_for_status()
    payload = resp.json()
    token = (payload.get("tokens") or {}).get("access_token") or payload.get("access_token")
    if not token:
        raise RuntimeError("Login response did not contain tokens.access_token.")
    return str(token)


def _is_valid_image_bytes(raw: bytes, mime_type: str) -> bool:
    if mime_type == "image/jpeg":
        return raw.startswith(b"\xff\xd8\xff")
    if mime_type == "image/png":
        return raw.startswith(b"\x89PNG\r\n\x1a\n")
    if mime_type == "image/webp":
        return len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP"
    return False


def download_verified_image(
    spec: ImageSpec,
    *,
    fetcher: httpx.Client | None = None,
    sleep_seconds: float = 1.1,
) -> bytes:
    """Download a verified Wikimedia Commons image politely and verify magic bytes."""
    if fetcher is not None:
        resp = fetcher.get(spec.direct_url)
        resp.raise_for_status()
        raw = resp.content
    else:
        with httpx.Client(
            headers={"User-Agent": WIKIMEDIA_USER_AGENT},
            timeout=30.0,
            follow_redirects=True,
        ) as dl_client:
            resp = dl_client.get(spec.direct_url)
            resp.raise_for_status()
            raw = resp.content
        if sleep_seconds > 0:
            time.sleep(sleep_seconds)
    if not _is_valid_image_bytes(raw, spec.mime_type):
        raise ValueError(
            f"Downloaded image for {spec.file_title} failed {spec.mime_type} magic-byte check."
        )
    return raw


def run_enrichment(
    *,
    apply: bool = False,
    offline: bool = False,
    base_url: str | None = None,
    overwrite_subresources: bool = False,
    upload_images: bool = True,
    only_ids: set[int] | None = None,
    api_client: httpx.Client | None = None,
    image_fetcher: httpx.Client | None = None,
) -> dict[str, Any]:
    """Run dry-run planning or authenticated Admin API enrichment."""
    resolved_base_url = (
        base_url
        or os.environ.get("LAKBAY_API_BASE_URL")
        or DEFAULT_API_BASE_URL
    ).rstrip("/")

    validated = validate_plan_schemas(ENRICHMENT_PLANS)
    plans = [
        p for p in ENRICHMENT_PLANS
        if only_ids is None or p.destination_id in only_ids
    ]

    if apply and offline:
        raise ValueError("--apply cannot be combined with --offline.")

    missing_creds = [
        k for k in ("LAKBAY_ADMIN_EMAIL", "LAKBAY_ADMIN_PASSWORD")
        if not os.environ.get(k)
    ]
    if apply and missing_creds:
        return {
            "mode": "apply-blocked-missing-creds",
            "api_base_url": resolved_base_url,
            "env_presence": env_readiness_booleans(),
            "missing_env_vars": missing_creds,
            "exit_code": 2,
            "actions": [],
        }

    own_client = api_client is None and not offline
    client = api_client or (
        httpx.Client(base_url=resolved_base_url, timeout=30.0)
        if not offline
        else None
    )

    try:
        if offline:
            catalog = offline_fixture_catalog(ENRICHMENT_PLANS)
        else:
            assert client is not None
            catalog = fetch_catalog(client)

        auth_headers: dict[str, str] = {}
        if apply:
            assert client is not None
            token = login_admin(
                client,
                email=os.environ["LAKBAY_ADMIN_EMAIL"],
                password=os.environ["LAKBAY_ADMIN_PASSWORD"],
            )
            auth_headers = {"Authorization": f"Bearer {token}"}

        actions: list[dict[str, Any]] = []
        counts = {
            "destinations_checked": 0,
            "patch_planned_or_applied": 0,
            "hours_planned_or_applied": 0,
            "prices_planned_or_applied": 0,
            "activities_planned_or_applied": 0,
            "images_planned_or_applied": 0,
            "subresources_preserved_skipped": 0,
        }

        for plan in plans:
            counts["destinations_checked"] += 1
            live_dest = catalog.get(plan.destination_id)
            if live_dest is None:
                actions.append({
                    "destination_id": plan.destination_id,
                    "name": plan.name,
                    "status": "missing_in_catalog",
                })
                continue

            patch_diff = compute_patch_diff(live_dest, plan)
            patch_json = (
                DestinationUpdate.model_validate(patch_diff).model_dump(
                    mode="json", exclude_unset=True
                )
                if patch_diff
                else {}
            )

            # GET-before-PUT check for structured subresources
            existing_hours = None
            existing_prices = None
            existing_activities = None
            if not offline:
                assert client is not None
                if plan.hours_payload is not None:
                    r_h = client.get(f"/destinations/{plan.destination_id}/hours")
                    r_h.raise_for_status()
                    existing_hours = r_h.json()
                if plan.prices_payload is not None:
                    r_p = client.get(f"/destinations/{plan.destination_id}/prices")
                    r_p.raise_for_status()
                    existing_prices = r_p.json()
                if plan.activities_payload is not None:
                    r_a = client.get(f"/destinations/{plan.destination_id}/activities")
                    r_a.raise_for_status()
                    existing_activities = r_a.json()

            do_hours = plan.hours_payload is not None and should_apply_hours(
                existing_hours, overwrite=overwrite_subresources
            )
            do_prices = plan.prices_payload is not None and should_apply_prices(
                existing_prices, overwrite=overwrite_subresources
            )
            do_activities = plan.activities_payload is not None and should_apply_activities(
                existing_activities, overwrite=overwrite_subresources
            )
            do_image = (
                upload_images
                and plan.image_spec is not None
                and not live_dest.get("image_url")
            )

            if plan.hours_payload is not None and not do_hours:
                counts["subresources_preserved_skipped"] += 1
            if plan.prices_payload is not None and not do_prices:
                counts["subresources_preserved_skipped"] += 1
            if plan.activities_payload is not None and not do_activities:
                counts["subresources_preserved_skipped"] += 1

            record_ops: list[str] = []
            if patch_json:
                counts["patch_planned_or_applied"] += 1
                record_ops.append("PATCH")
                if apply:
                    assert client is not None
                    r = client.patch(
                        f"/destinations/{plan.destination_id}",
                        json=patch_json,
                        headers=auth_headers,
                    )
                    r.raise_for_status()

            if do_hours:
                counts["hours_planned_or_applied"] += 1
                record_ops.append("PUT /hours")
                if apply:
                    assert client is not None
                    r = client.put(
                        f"/destinations/{plan.destination_id}/hours",
                        json=validated[plan.destination_id]["hours"],
                        headers=auth_headers,
                    )
                    r.raise_for_status()

            if do_prices:
                counts["prices_planned_or_applied"] += 1
                record_ops.append("PUT /prices")
                if apply:
                    assert client is not None
                    r = client.put(
                        f"/destinations/{plan.destination_id}/prices",
                        json=validated[plan.destination_id]["prices"],
                        headers=auth_headers,
                    )
                    r.raise_for_status()

            if do_activities:
                counts["activities_planned_or_applied"] += 1
                record_ops.append("PUT /activities")
                if apply:
                    assert client is not None
                    r = client.put(
                        f"/destinations/{plan.destination_id}/activities",
                        json=validated[plan.destination_id]["activities"],
                        headers=auth_headers,
                    )
                    r.raise_for_status()

            if do_image and plan.image_spec is not None:
                counts["images_planned_or_applied"] += 1
                record_ops.append("POST /image")
                if apply:
                    assert client is not None
                    img_bytes = download_verified_image(
                        plan.image_spec,
                        fetcher=image_fetcher,
                        sleep_seconds=0.0 if image_fetcher is not None else 1.1,
                    )
                    ext = "jpg" if plan.image_spec.mime_type == "image/jpeg" else "png"
                    r = client.post(
                        f"/destinations/{plan.destination_id}/image",
                        files={"file": (f"dest_{plan.destination_id}.{ext}", img_bytes, plan.image_spec.mime_type)},
                        headers=auth_headers,
                    )
                    r.raise_for_status()

            actions.append({
                "destination_id": plan.destination_id,
                "name": plan.name,
                "ops": record_ops,
                "patch_fields": sorted(patch_json.keys()),
                "projected_quality": project_data_quality(plan, live_dest),
                "source_urls": list(plan.source_urls),
            })

        return {
            "mode": "live-applied" if apply else ("dry-run-offline" if offline else "dry-run-live-read"),
            "api_base_url": resolved_base_url,
            "env_presence": env_readiness_booleans(),
            "catalog_count": len(catalog),
            "counts": counts,
            "staged_clips_count": len(STAGED_CLIPS),
            "actions": actions,
            "exit_code": 0,
        }
    finally:
        if own_client and client is not None:
            client.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate payloads and print planned non-destructive diffs (default mode).",
    )
    mode_group.add_argument(
        "--apply",
        action="store_true",
        help="Execute authenticated Admin API writes (requires LAKBAY_ADMIN_EMAIL and LAKBAY_ADMIN_PASSWORD).",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Run dry-run against local baseline fixture instead of fetching live GET /destinations.",
    )
    parser.add_argument(
        "--base-url",
        default=None,
        help=f"Override API base URL (default: LAKBAY_API_BASE_URL or {DEFAULT_API_BASE_URL}).",
    )
    parser.add_argument(
        "--overwrite-subresources",
        action="store_true",
        help="Replace structured /hours, /prices, /activities even if non-empty rows already exist.",
    )
    parser.add_argument(
        "--no-upload-images",
        action="store_true",
        help="Skip POST /destinations/{id}/image uploads even when verified CC/PD photos are staged.",
    )
    parser.add_argument(
        "--only-ids",
        default=None,
        help="Comma-separated destination IDs to process (default: all curated targets).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable non-secret JSON summary.",
    )
    args = parser.parse_args(argv)

    only_ids = (
        {int(part.strip()) for part in args.only_ids.split(",") if part.strip()}
        if args.only_ids
        else None
    )

    try:
        summary = run_enrichment(
            apply=args.apply,
            offline=args.offline,
            base_url=args.base_url,
            overwrite_subresources=args.overwrite_subresources,
            upload_images=not args.no_upload_images,
            only_ids=only_ids,
        )
    except ValueError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    if summary["exit_code"] != 0:
        missing = ", ".join(summary.get("missing_env_vars", []))
        print(
            f"Cannot run --apply: missing required environment variable(s): {missing}. "
            "Set them in your shell environment and re-run.",
            file=sys.stderr,
        )
        return int(summary["exit_code"])

    if args.json:
        print(json.dumps(summary, indent=2, default=str))
        return 0

    print(f"Mode: {summary['mode']}")
    print(f"API Base URL: {summary['api_base_url']}")
    print(
        "Env Keys (booleans only): "
        + ", ".join(f"{k}={'SET' if v else 'UNSET'}" for k, v in summary["env_presence"].items())
    )
    print(f"Catalog records inspected: {summary['catalog_count']}")
    print(f"Summary counts: {summary['counts']}")
    print(f"Staged sample clips (post-migration 2026_11_27_0415): {summary['staged_clips_count']}")
    for act in summary["actions"]:
        ops_str = ", ".join(act.get("ops") or ["no-op"])
        print(
            f"  [{act['destination_id']:2d}] {act['name']} -> {ops_str}"
            + (f" | patch={act['patch_fields']}" if act.get("patch_fields") else "")
            + f" | quality={act.get('projected_quality')}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
