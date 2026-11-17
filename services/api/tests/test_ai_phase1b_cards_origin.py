"""Places in a town, text that matches the cards, and the traveler's start place."""

import json

from app.features.ai import router as ai_router_module
from app.integrations.groq.client import get_groq_client
from app.integrations.groq.prompts import build_chat_messages, origin_applies
from app.features.ai.schemas import AIChatRequest
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)
from tests.test_planning_chat import CandidateOSRM, verified_arrival


def _town_catalog(client):
    admin = admin_headers(client)
    made = {}
    for i, (name, extra) in enumerate([
        ("Panabo City Parks and Plaza", {"location": "Panabo City", "category": "park"}),
        ("Museo Panabo", {"location": "Panabo City", "category": "museum"}),
        ("Panabo Mangrove Forest Park", {"location": "Panabo City", "category": "nature park"}),
        ("Sky Deck Garden Cafe", {"location": "Panabo City", "category": "cafe"}),
        ("Sky Deck Garden Cafe ", {"location": "Panabo City", "category": "cafe"}),
        ("Eden Nature Park", {"location": "Toril, Davao City", "category": "nature park"}),
    ]):
        made[name.strip()] = create_destination(
            client, headers=admin, name=name, district="Davao del Norte",
            **extra, **verified_arrival(i),
        )
    return made


def _ask(client, message, model_reply, state, *, use_rag=True):
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([model_reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={"message": message, "use_rag": use_rag, "planning_state": state},
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_a_request_for_places_in_a_town_shows_that_towns_places(client, monkeypatch) -> None:
    """Live case: "is there a place to go in panabo?" got a text answer and no cards."""
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    made = _town_catalog(client)
    reply = json.dumps({
        "chat_response": "Yes, Panabo has a few places worth a visit.",
        "state_updates": {}, "intent": "question",
    })

    body = _ask(client, "is there a place to go in panabo?", reply, {
        "origin": {"label": "New Visayas, Panabo", "lat": 7.3079, "lng": 125.6841},
        "selected_transport_option_ids": ["mode:personal_vehicle"],
    })

    cards = body["planning"]["recommendations"]
    names = [c["name"].strip() for c in cards]
    assert 1 <= len(cards) <= 5
    assert "Eden Nature Park" not in names  # not in Panabo
    assert len(names) == len(set(names))  # the duplicate entry is listed once
    assert set(names) <= {n for n in made if n != "Eden Nature Park"}


def test_a_question_about_one_named_place_does_not_become_a_town_list(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    _town_catalog(client)
    reply = json.dumps({
        "chat_response": "Museo Panabo opens in the morning.",
        "state_updates": {}, "intent": "question",
    })

    body = _ask(client, "What time does Museo Panabo open?", reply,
                {"origin": {"label": "New Visayas, Panabo"}})

    assert body["planning"]["recommendations"] == []


def test_text_never_names_a_place_that_is_not_a_card(client, monkeypatch) -> None:
    """Live case: the text named Dahican Surf Resort while the cards showed others."""
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    admin = admin_headers(client)
    names = [f"{w} Beach Resort" for w in (
        "Alder Cove", "Brisa Bay", "Cobalt Shore", "Dune Point", "Ember Sands",
        "Fjord Strand", "Garnet Reef",
    )]
    for i, name in enumerate(names):
        create_destination(
            client, headers=admin, name=name, category="beach", **verified_arrival(i),
        )
    text = " ".join(f"Try {n}." for n in names) + " Bring sunscreen."
    reply = json.dumps({
        "chat_response": text, "state_updates": {},
        "intent": "show_places", "place_query": {"categories": ["beach"], "limit": 5},
    })

    body = _ask(client, "show me beach resorts", reply, {
        "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
        "selected_transport_option_ids": ["mode:personal_vehicle"],
    })

    card_names = {c["name"] for c in body["planning"]["recommendations"]}
    assert len(card_names) == 5
    for name in names:
        assert (name in body["chat_response"]) == (name in card_names), name
    assert "Bring sunscreen." in body["chat_response"]


def test_a_route_from_davao_city_is_not_given_to_a_traveler_starting_elsewhere(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    reply = json.dumps({
        "chat_response": "Panabo is calm. It takes 45 to 60 minutes from Davao City by bus. "
                         "Bring a hat.",
        "state_updates": {}, "intent": "question",
    })

    body = _ask(client, "How is Panabo?", reply,
                {"origin": {"label": "New Visayas, Panabo"}}, use_rag=False)

    text = body["chat_response"]
    assert "from Davao City" not in text
    assert "Panabo is calm." in text and "Bring a hat." in text


def test_a_route_from_davao_city_stays_for_a_traveler_starting_there(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    reply = json.dumps({
        "chat_response": "It takes about 60 minutes from Davao City by bus.",
        "state_updates": {}, "intent": "question",
    })

    body = _ask(client, "How long by bus?", reply,
                {"origin": {"label": "Davao City"}}, use_rag=False)

    assert "from Davao City" in body["chat_response"]


def test_transport_records_say_whether_they_start_at_the_travelers_place():
    assert origin_applies("Davao City", "Davao City")
    assert origin_applies("Davao City Proper", "Davao City")
    assert not origin_applies("Davao City", "New Visayas, Panabo")
    assert origin_applies("Panabo Terminal", "New Visayas, Panabo")
    assert not origin_applies("", "Davao City")
    assert not origin_applies("Davao City", None)


def test_the_planning_prompt_carries_the_start_place_and_flags_routes():
    messages = build_chat_messages(
        request=AIChatRequest(
            message="How do I get there?",
            planning_state={"origin": {"label": "New Visayas, Panabo"}},
        ),
        retrieved_context=[
            {"source": "transportation", "source_id": 1, "title": "Bus",
             "facts": {"route_from": "Davao City", "route_to": "Panabo", "price": "150.00"}},
            {"source": "destination", "source_id": 2, "title": "Park", "facts": {"name": "Park"}},
        ],
    )
    assert "START PLACE" in messages[0]["content"]
    assert "NAMES" in messages[0]["content"]
    payload = json.loads(messages[-1]["content"])
    assert payload["traveler_origin"] == {"label": "New Visayas, Panabo", "is_davao_city": False}
    bus, park = payload["retrieved_lakbay_context"]
    assert bus["facts"]["starts_at_traveler_origin"] is False
    assert "starts_at_traveler_origin" not in park["facts"]
