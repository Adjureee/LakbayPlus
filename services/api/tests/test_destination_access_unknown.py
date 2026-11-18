"""Accessibility flags can be unknown, plus status, booking and visit-length fields."""

import pytest
from pydantic import ValidationError

from app.features.ai.rag import _destination_document
from app.features.destinations.schemas import DestinationUpdate
from tests.test_ai_rag import destination as fake_place
from tests.test_phase5_ai_itineraries import admin_headers, create_destination

FLAGS = (
    "is_kid_friendly", "is_wheelchair_accessible", "is_pet_friendly",
    "is_elderly_friendly", "family_friendly", "couple_friendly", "group_friendly",
)


# --- unknown is not no ------------------------------------------------------------------


def test_a_new_place_starts_with_every_flag_unknown(client) -> None:
    # The shared test payload sets two flags; say nothing about any of them here.
    place = create_destination(
        client, headers=admin_headers(client), family_friendly=None, group_friendly=None,
    )
    fetched = client.get(f"/api/v1/destinations/{place['destination_id']}").json()
    assert all(fetched[flag] is None for flag in FLAGS)


def test_an_admin_can_set_a_flag_to_yes_no_and_back_to_unknown(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}"

    yes = client.patch(url, headers=admin, json={"is_wheelchair_accessible": True})
    assert yes.json()["is_wheelchair_accessible"] is True
    no = client.patch(url, headers=admin, json={"is_wheelchair_accessible": False})
    assert no.json()["is_wheelchair_accessible"] is False  # checked, no
    unknown = client.patch(url, headers=admin, json={"is_wheelchair_accessible": None})
    assert unknown.json()["is_wheelchair_accessible"] is None
    # Other flags are untouched by the three saves above.
    assert unknown.json()["is_kid_friendly"] is None


def test_filters_match_only_known_values(client) -> None:
    admin = admin_headers(client)
    yes = create_destination(client, headers=admin, name="Yes Park")
    no = create_destination(client, headers=admin, name="No Park")
    create_destination(client, headers=admin, name="Unknown Park")
    client.patch(f"/api/v1/destinations/{yes['destination_id']}", headers=admin,
                 json={"is_kid_friendly": True})
    client.patch(f"/api/v1/destinations/{no['destination_id']}", headers=admin,
                 json={"is_kid_friendly": False})

    def names(query):
        rows = client.get(f"/api/v1/destinations?{query}").json()
        return sorted(r["name"] for r in rows)

    assert names("kid_friendly=true") == ["Yes Park"]
    assert names("kid_friendly=false") == ["No Park"]  # unchecked is not "no"
    assert len(names("limit=100")) == 3


# --- what the AI is told ----------------------------------------------------------------


def test_an_unknown_flag_is_missing_from_the_ai_record_and_a_no_is_kept():
    place = fake_place(1, "Eden Nature Park", "Davao City",
                       is_wheelchair_accessible=None, is_kid_friendly=False,
                       is_pet_friendly=True)
    facts = _destination_document(place).payload
    assert "wheelchair_accessible" not in facts  # never checked
    assert facts["kid_friendly"] is False  # checked, no
    assert facts["pet_friendly"] is True


def test_status_booking_and_visit_length_reach_the_ai_record():
    place = fake_place(1, "Eden Nature Park", "Davao City",
                       operating_status="temporarily_closed",
                       booking_requirement="required", booking_note="Call 2 days ahead",
                       typical_visit_min_minutes=90, typical_visit_max_minutes=180)
    doc = _destination_document(place)
    assert doc.payload["operating_status"] == "temporarily_closed"
    assert doc.payload["booking_requirement"] == "required"
    assert doc.payload["typical_visit_min_minutes"] == 90
    assert "Call 2 days ahead" in doc.text


# --- the new fields ---------------------------------------------------------------------


def test_status_booking_and_visit_length_are_validated():
    DestinationUpdate.model_validate({
        "operating_status": "open", "booking_requirement": "recommended",
        "typical_visit_min_minutes": 60, "typical_visit_max_minutes": 120,
    })
    for bad in (
        {"operating_status": "haunted"},
        {"booking_requirement": "maybe"},
        {"typical_visit_min_minutes": 0},
        {"typical_visit_min_minutes": 120, "typical_visit_max_minutes": 60},
    ):
        with pytest.raises(ValidationError):
            DestinationUpdate.model_validate(bad)


def test_the_new_fields_save_and_read_back(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}"
    saved = client.patch(url, headers=admin, json={
        "operating_status": "open", "booking_requirement": "not_required",
        "booking_note": "Walk-ins welcome", "parking_note": "Free parking",
        "typical_visit_min_minutes": 60, "typical_visit_max_minutes": 120,
        "best_time_basis": "Cooler in the morning",
    })
    assert saved.status_code == 200, saved.text
    body = client.get(url).json()
    assert body["operating_status"] == "open"
    assert body["typical_visit_max_minutes"] == 120
    assert body["best_time_basis"] == "Cooler in the morning"
    assert client.patch(url, headers=admin, json={"operating_status": "haunted"}
                        ).status_code == 422
