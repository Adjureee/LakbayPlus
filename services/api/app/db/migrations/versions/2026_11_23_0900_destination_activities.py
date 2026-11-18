"""Structured activities for destinations.

Revision ID: 2026_11_23_0900
Revises: 2026_11_22_0900

Step 4 of docs/PLACE_DATA_DESIGN.md. Additive only: one new table,
destination_activities. Nothing on destinations changes, and the free-text
destinations.activities column stays as the fallback for places not converted yet.

Run on Neon BEFORE deploying the code: the AI retrieval reads this table.

Downgrade drops the table (and the activities entered in it).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_23_0900"
down_revision: str | Sequence[str] | None = "2026_11_22_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "destination_activities",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "destination_id", sa.Integer(),
            sa.ForeignKey("destinations.destination_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("availability", sa.String(length=20), nullable=True),
        sa.Column("schedule_note", sa.Text(), nullable=True),
        sa.Column("last_admission_at", sa.Time(), nullable=True),
        sa.Column("duration_min_minutes", sa.Integer(), nullable=True),
        sa.Column("duration_max_minutes", sa.Integer(), nullable=True),
        sa.Column("extra_fee", sa.Numeric(10, 2), nullable=True),
        sa.Column("fee_included_in_admission", sa.Boolean(), nullable=True),
        sa.Column("effort_level", sa.String(length=20), nullable=True),
        sa.Column("accessibility_note", sa.Text(), nullable=True),
        sa.Column("min_age", sa.SmallInteger(), nullable=True),
        sa.Column("max_age", sa.SmallInteger(), nullable=True),
        sa.Column("restriction_note", sa.Text(), nullable=True),
        sa.Column("weather_dependency", sa.String(length=20), nullable=True),
        sa.Column("best_time_note", sa.Text(), nullable=True),
        sa.Column("best_time_basis", sa.Text(), nullable=True),
        sa.Column("source_url", sa.String(length=2048), nullable=True),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "availability IS NULL OR availability IN "
            "('always', 'scheduled', 'seasonal', 'by_arrangement')",
            name="ck_destination_activities_availability",
        ),
        sa.CheckConstraint(
            "effort_level IS NULL OR effort_level IN ('easy', 'moderate', 'challenging')",
            name="ck_destination_activities_effort",
        ),
        sa.CheckConstraint(
            "weather_dependency IS NULL OR weather_dependency IN "
            "('none', 'dry_weather', 'calm_seas', 'daylight')",
            name="ck_destination_activities_weather",
        ),
        sa.CheckConstraint(
            "extra_fee IS NULL OR extra_fee >= 0", name="ck_destination_activities_fee",
        ),
        sa.CheckConstraint(
            "(duration_min_minutes IS NULL OR duration_min_minutes > 0) AND "
            "(duration_max_minutes IS NULL OR duration_max_minutes > 0) AND "
            "(duration_min_minutes IS NULL OR duration_max_minutes IS NULL OR "
            "duration_min_minutes <= duration_max_minutes)",
            name="ck_destination_activities_duration",
        ),
        sa.CheckConstraint(
            "(min_age IS NULL OR min_age >= 0) AND (max_age IS NULL OR max_age >= 0) AND "
            "(min_age IS NULL OR max_age IS NULL OR min_age <= max_age)",
            name="ck_destination_activities_ages",
        ),
    )
    op.create_index(
        "ix_destination_activities_destination_id", "destination_activities",
        ["destination_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_destination_activities_destination_id", table_name="destination_activities",
    )
    op.drop_table("destination_activities")
