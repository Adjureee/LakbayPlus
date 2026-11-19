"""Accessibility and suitability flags can be unknown; status, booking, visit length.

Revision ID: 2026_11_24_0900
Revises: 2026_11_23_0900

Step 1 of docs/PLACE_DATA_DESIGN.md.

1. The seven suitability flags (kid, wheelchair, pet, elderly, family, couple, group)
   become nullable. NULL means "not checked"; false means "checked, no".
2. DATA CHANGE: every existing false becomes NULL. Nobody can tell which false values
   were checked and which were only the old default, so none are kept as "no". true
   values are untouched.
3. New nullable columns: operating_status, booking_requirement, booking_note,
   parking_note, typical_visit_min_minutes, typical_visit_max_minutes,
   best_time_basis, each with a check constraint where it has a fixed set of values.

Run on Neon BEFORE deploying the code: the app reads the new columns on every
destination query.

Downgrade turns NULL back into false (a place that was "not checked" reads as "no"
again), restores NOT NULL on the flags, and drops the new columns.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_24_0900"
down_revision: str | Sequence[str] | None = "2026_11_23_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

FLAGS = ['is_kid_friendly', 'is_wheelchair_accessible', 'is_pet_friendly', 'is_elderly_friendly', 'family_friendly', 'couple_friendly', 'group_friendly']


def upgrade() -> None:
    for flag in FLAGS:
        op.alter_column("destinations", flag, existing_type=sa.Boolean(), nullable=True)
    # false was the default, not a finding: the unknown value says so honestly.
    for flag in FLAGS:
        op.execute(f"UPDATE destinations SET {flag} = NULL WHERE {flag} = false")

    op.add_column("destinations", sa.Column("operating_status", sa.String(length=20), nullable=True))
    op.add_column("destinations", sa.Column("booking_requirement", sa.String(length=20), nullable=True))
    op.add_column("destinations", sa.Column("booking_note", sa.Text(), nullable=True))
    op.add_column("destinations", sa.Column("parking_note", sa.Text(), nullable=True))
    op.add_column("destinations", sa.Column("typical_visit_min_minutes", sa.Integer(), nullable=True))
    op.add_column("destinations", sa.Column("typical_visit_max_minutes", sa.Integer(), nullable=True))
    op.add_column("destinations", sa.Column("best_time_basis", sa.Text(), nullable=True))
    op.create_check_constraint(
        "ck_destinations_operating_status", "destinations",
        "operating_status IS NULL OR operating_status IN "
        "('open', 'temporarily_closed', 'permanently_closed')",
    )
    op.create_check_constraint(
        "ck_destinations_booking_requirement", "destinations",
        "booking_requirement IS NULL OR booking_requirement IN "
        "('required', 'recommended', 'not_required')",
    )
    op.create_check_constraint(
        "ck_destinations_typical_visit", "destinations",
        "(typical_visit_min_minutes IS NULL OR typical_visit_min_minutes > 0) AND "
        "(typical_visit_max_minutes IS NULL OR typical_visit_max_minutes > 0) AND "
        "(typical_visit_min_minutes IS NULL OR typical_visit_max_minutes IS NULL OR "
        "typical_visit_min_minutes <= typical_visit_max_minutes)",
    )


def downgrade() -> None:
    op.drop_constraint("ck_destinations_typical_visit", "destinations", type_="check")
    op.drop_constraint("ck_destinations_booking_requirement", "destinations", type_="check")
    op.drop_constraint("ck_destinations_operating_status", "destinations", type_="check")
    for column in (
        "best_time_basis", "typical_visit_max_minutes", "typical_visit_min_minutes",
        "parking_note", "booking_note", "booking_requirement", "operating_status",
    ):
        op.drop_column("destinations", column)
    for flag in FLAGS:
        op.execute(f"UPDATE destinations SET {flag} = false WHERE {flag} IS NULL")
    for flag in FLAGS:
        op.alter_column("destinations", flag, existing_type=sa.Boolean(), nullable=False)
