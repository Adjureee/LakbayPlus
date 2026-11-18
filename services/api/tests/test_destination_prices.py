"""Structured prices: reading, validation, the admin API and what the AI is told."""

from decimal import Decimal
from types import SimpleNamespace as N

import pytest
from pydantic import ValidationError

from app.features.ai.rag import _destination_document
from app.features.destinations.prices import money_text, prices_summary
from app.features.destinations.schemas import DestinationPricesUpdate
from tests.test_ai_rag import destination as fake_place
from tests.test_phase5_ai_itineraries import admin_headers, create_destination, user_headers


def _price(item="entrance", audience="adult", amount="100", unit="per_person",
           age_min=None, age_max=None):
    return N(item=item, audience=audience, amount=Decimal(amount), unit=unit,
             age_min=age_min, age_max=age_max)


# --- reading ---------------------------------------------------------------------------


def test_money_text_drops_empty_cents():
    assert money_text(Decimal("100.00")) == "₱100"
    assert money_text(Decimal("50.50")) == "₱50.50"
    assert money_text(Decimal("1500")) == "₱1,500"


def test_summary_groups_by_item_and_names_audiences_and_ages():
    rows = [
        _price(),
        _price(audience="child", amount="50", age_min=4, age_max=12),
        _price(item="parking", audience="everyone", amount="30", unit="per_vehicle"),
    ]
    assert prices_summary(rows) == (
        "Entrance: adult ₱100 per person, child (ages 4 to 12) ₱50 per person; "
        "Parking: everyone ₱30 per vehicle"
    )


def test_zero_is_free_and_no_rows_is_unknown():
    assert prices_summary([_price(amount="0")]) == "Entrance: adult free"
    assert prices_summary([]) is None  # unknown, never "free"


# --- validation ------------------------------------------------------------------------


def _update(**fields):
    return DestinationPricesUpdate.model_validate(fields)


def test_prices_must_make_sense():
    ok = {"item": "entrance", "audience": "adult", "amount": "100", "unit": "per_person"}
    _update(prices=[ok])
    for bad in (
        {**ok, "amount": "-5"},
        {**ok, "item": "souvenir"},
        {**ok, "audience": "alien"},
        {**ok, "unit": "per_cow"},
        {**ok, "age_min": 12, "age_max": 4},
        {**ok, "amount": "10.123"},
    ):
        with pytest.raises(ValidationError):
            _update(prices=[bad])
    with pytest.raises(ValidationError):  # the same price twice
        _update(prices=[ok, ok])
    with pytest.raises(ValidationError):
        _update(fees_source_url="not a url")


# --- the admin API ---------------------------------------------------------------------

PAYLOAD = {
    "fees_source_url": "https://example.com/fees",
    "fees_verified_at": "2026-11-01T00:00:00+08:00",
    "prices": [
        {"item": "entrance", "audience": "adult", "amount": "100", "unit": "per_person"},
        {"item": "entrance", "audience": "child", "amount": "50.00", "unit": "per_person",
         "age_min": 4, "age_max": 12, "note": "Free under 4"},
        {"item": "parking", "audience": "everyone", "amount": "0", "unit": "per_vehicle"},
    ],
}


def test_an_admin_saves_and_anyone_reads_the_prices(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/prices"

    empty = client.get(url)
    assert empty.status_code == 200
    assert empty.json()["summary"] is None and empty.json()["prices"] == []

    saved = client.put(url, headers=admin, json=PAYLOAD)
    assert saved.status_code == 200, saved.text
    body = saved.json()
    assert body["summary"].startswith("Entrance: adult ₱100 per person")
    assert "Parking: everyone free" in body["summary"]
    assert body["prices"][1]["note"] == "Free under 4"
    assert body["data_quality"] in {"supported", "estimated"}
    assert client.get(url).json()["summary"] == body["summary"]

    # A second save replaces everything: no leftovers from the first.
    again = client.put(url, headers=admin, json={"prices": [PAYLOAD["prices"][0]]})
    assert again.status_code == 200
    assert len(again.json()["prices"]) == 1


def test_only_an_admin_can_change_prices_and_bad_input_is_refused(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/prices"

    assert client.put(url, json=PAYLOAD).status_code in {401, 403}
    assert client.put(url, headers=user_headers(client), json=PAYLOAD).status_code == 403
    bad = {"prices": [{"item": "entrance", "audience": "adult", "amount": "-1",
                       "unit": "per_person"}]}
    assert client.put(url, headers=admin, json=bad).status_code == 422
    assert client.get("/api/v1/destinations/999999/prices").status_code == 404
    assert client.put("/api/v1/destinations/999999/prices", headers=admin,
                      json=PAYLOAD).status_code == 404


def test_hours_and_prices_are_saved_independently(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    base = f"/api/v1/destinations/{place['destination_id']}"
    assert client.put(f"{base}/prices", headers=admin, json=PAYLOAD).status_code == 200
    assert client.put(f"{base}/hours", headers=admin,
                      json={"open_24_hours": True}).status_code == 200
    assert len(client.get(f"{base}/prices").json()["prices"]) == 3


# --- what the AI is told ---------------------------------------------------------------


def test_the_ai_record_carries_structured_prices_with_their_trust_level():
    place = fake_place(1, "Eden Nature Park", "Davao City")
    rows = [_price(), _price(audience="child", amount="50", age_min=4, age_max=12)]
    doc = _destination_document(place, prices=rows)
    assert doc.payload["prices"].startswith("Entrance: adult ₱100 per person")
    assert doc.payload["fees_data_quality"] == "estimated"  # no verified date yet
    assert "₱100" in doc.text

    bare = _destination_document(place).payload
    assert bare.get("prices") is None  # empty facts are left out
    assert bare["fees_data_quality"] in {"estimated", "unknown"}
