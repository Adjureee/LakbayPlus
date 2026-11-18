"""Structured prices for destinations.

Revision ID: 2026_11_22_0900
Revises: 2026_11_21_0900

Step 3 of docs/PLACE_DATA_DESIGN.md. Additive only: two nullable columns on
destinations (fees_source_url, fees_verified_at) and one new table, destination_prices
(item, audience, amount, unit, optional ages and a note). The text columns
entrance_fee, overnight_fee and estimated_cost are untouched and stay the fallback.

Run on Neon BEFORE deploying the code: the app reads the new destinations columns on
every destination query.

Downgrade drops the table and the two columns (and the prices entered in them).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_22_0900"
down_revision: str | Sequence[str] | None = "2026_11_21_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "destinations", sa.Column("fees_source_url", sa.String(length=2048), nullable=True),
    )
    op.add_column(
        "destinations",
        sa.Column("fees_verified_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "destination_prices",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "destination_id", sa.Integer(),
            sa.ForeignKey("destinations.destination_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("item", sa.String(length=20), nullable=False),
        sa.Column("audience", sa.String(length=20), nullable=False),
        sa.Column("amount", sa.Numeric(10, 2), nullable=False),
        sa.Column("unit", sa.String(length=20), nullable=False),
        sa.Column("age_min", sa.SmallInteger(), nullable=True),
        sa.Column("age_max", sa.SmallInteger(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.CheckConstraint(
            "item IN ('entrance', 'overnight', 'parking', 'cottage', 'other')",
            name="ck_destination_prices_item",
        ),
        sa.CheckConstraint(
            "audience IN ('adult', 'child', 'senior', 'pwd', 'student', 'resident', "
            "'non_resident', 'everyone')",
            name="ck_destination_prices_audience",
        ),
        sa.CheckConstraint(
            "unit IN ('per_person', 'per_group', 'per_vehicle', 'per_night')",
            name="ck_destination_prices_unit",
        ),
        sa.CheckConstraint("amount >= 0", name="ck_destination_prices_amount"),
        sa.CheckConstraint(
            "(age_min IS NULL OR age_min >= 0) AND (age_max IS NULL OR age_max >= 0) AND "
            "(age_min IS NULL OR age_max IS NULL OR age_min <= age_max)",
            name="ck_destination_prices_ages",
        ),
    )
    op.create_index("ix_destination_prices_destination_id", "destination_prices", ["destination_id"])


def downgrade() -> None:
    op.drop_index("ix_destination_prices_destination_id", table_name="destination_prices")
    op.drop_table("destination_prices")
    op.drop_column("destinations", "fees_verified_at")
    op.drop_column("destinations", "fees_source_url")
