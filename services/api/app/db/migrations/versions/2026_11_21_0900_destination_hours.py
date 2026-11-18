"""Structured opening hours for destinations.

Revision ID: 2026_11_21_0900
Revises: 2026_11_20_0900

Step 2 of docs/PLACE_DATA_DESIGN.md. Additive only: three nullable columns on
destinations (open_24_hours, hours_source_url, hours_verified_at) and two new tables,
destination_hours (weekly windows) and destination_hour_exceptions (date-specific
changes). The text column destinations.operating_hours is untouched and stays the
fallback for places without structured hours.

Downgrade drops the two tables and the three columns (and the hours entered in them).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_21_0900"
down_revision: str | Sequence[str] | None = "2026_11_20_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("destinations", sa.Column("open_24_hours", sa.Boolean(), nullable=True))
    op.add_column(
        "destinations", sa.Column("hours_source_url", sa.String(length=2048), nullable=True),
    )
    op.add_column(
        "destinations",
        sa.Column("hours_verified_at", sa.DateTime(timezone=True), nullable=True),
    )

    op.create_table(
        "destination_hours",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "destination_id", sa.Integer(),
            sa.ForeignKey("destinations.destination_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("weekday", sa.SmallInteger(), nullable=False),
        sa.Column("opens_at", sa.Time(), nullable=True),
        sa.Column("closes_at", sa.Time(), nullable=True),
        sa.Column("is_closed", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("last_admission_at", sa.Time(), nullable=True),
        sa.CheckConstraint("weekday >= 0 AND weekday <= 6", name="ck_destination_hours_weekday"),
        sa.CheckConstraint(
            "(is_closed AND opens_at IS NULL AND closes_at IS NULL "
            "AND last_admission_at IS NULL) OR "
            "(NOT is_closed AND opens_at IS NOT NULL AND closes_at IS NOT NULL "
            "AND opens_at < closes_at)",
            name="ck_destination_hours_window",
        ),
    )
    op.create_index("ix_destination_hours_destination_id", "destination_hours", ["destination_id"])

    op.create_table(
        "destination_hour_exceptions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "destination_id", sa.Integer(),
            sa.ForeignKey("destinations.destination_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("starts_on", sa.Date(), nullable=False),
        sa.Column("ends_on", sa.Date(), nullable=False),
        sa.Column("is_closed", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("opens_at", sa.Time(), nullable=True),
        sa.Column("closes_at", sa.Time(), nullable=True),
        sa.Column("reason", sa.String(length=255), nullable=True),
        sa.CheckConstraint("starts_on <= ends_on", name="ck_destination_hour_exceptions_range"),
        sa.CheckConstraint(
            "(is_closed AND opens_at IS NULL AND closes_at IS NULL) OR "
            "(NOT is_closed AND opens_at IS NOT NULL AND closes_at IS NOT NULL "
            "AND opens_at < closes_at)",
            name="ck_destination_hour_exceptions_window",
        ),
    )
    op.create_index(
        "ix_destination_hour_exceptions_destination_id",
        "destination_hour_exceptions", ["destination_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_destination_hour_exceptions_destination_id",
        table_name="destination_hour_exceptions",
    )
    op.drop_table("destination_hour_exceptions")
    op.drop_index("ix_destination_hours_destination_id", table_name="destination_hours")
    op.drop_table("destination_hours")
    op.drop_column("destinations", "hours_verified_at")
    op.drop_column("destinations", "hours_source_url")
    op.drop_column("destinations", "open_24_hours")
