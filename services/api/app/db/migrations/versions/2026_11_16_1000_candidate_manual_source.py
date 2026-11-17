"""Allow review-queue candidates that are not OpenStreetMap objects.

Revision ID: 2026_11_16_1000
Revises: 2026_11_15_1200

Admins can drop a pin on the admin map for a place missing from
OpenStreetMap. Such candidates have source = 'manual' and no OSM identity.
Existing rows become source = 'osm' and keep their OSM identity, which stays
required for that source and unique per OSM object.

Downgrade: rows with source = 'manual' have no OSM identity and must be
deleted (or given one) first, or restoring NOT NULL fails.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_16_1000"
down_revision: str | Sequence[str] | None = "2026_11_15_1200"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "destination_candidates",
        sa.Column(
            "source",
            sa.String(20),
            nullable=False,
            server_default="osm",
        ),
    )
    for column, type_ in (
        ("osm_type", sa.String(16)),
        ("osm_id", sa.BigInteger()),
        ("osm_url", sa.String(2048)),
    ):
        op.alter_column(
            "destination_candidates", column, existing_type=type_, nullable=True
        )
    op.create_check_constraint(
        "ck_destination_candidates_source",
        "destination_candidates",
        "source IN ('osm', 'manual')",
    )
    op.create_check_constraint(
        "ck_destination_candidates_osm_identity_for_osm",
        "destination_candidates",
        "source <> 'osm' OR "
        "(osm_type IS NOT NULL AND osm_id IS NOT NULL AND osm_url IS NOT NULL)",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_destination_candidates_osm_identity_for_osm",
        "destination_candidates",
        type_="check",
    )
    op.drop_constraint(
        "ck_destination_candidates_source", "destination_candidates", type_="check"
    )
    for column, type_ in (
        ("osm_type", sa.String(16)),
        ("osm_id", sa.BigInteger()),
        ("osm_url", sa.String(2048)),
    ):
        op.alter_column(
            "destination_candidates", column, existing_type=type_, nullable=False
        )
    op.drop_column("destination_candidates", "source")
