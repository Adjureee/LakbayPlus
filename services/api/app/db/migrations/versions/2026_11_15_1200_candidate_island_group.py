"""Add island_group to destination candidates.

Revision ID: 2026_11_15_1200
Revises: 2026_11_15_1100

Additive and nullable. Fill existing rows with
`python -m scripts.backfill_island_groups --apply`, which uses the OSM island
outlines in app/features/sea_links/data/island_outlines.json.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_15_1200"
down_revision: str | Sequence[str] | None = "2026_11_15_1100"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "destination_candidates",
        sa.Column("island_group", sa.String(50), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("destination_candidates", "island_group")
